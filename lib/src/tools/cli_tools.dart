/// Constrained CLI executor tool (`run_cli`).
///
/// Replaces the hand-maintained kan + outline MCP servers with a single tool
/// that shells out to the vendored zero-dependency CLIs
/// (`cli-tools/kan.mjs`, `cli-tools/outline.mjs`). Those CLIs wrap the *full*
/// Kan.bn and Outline REST surfaces — including onboarding (invite links, user
/// invites) that the MCP subset lacked and that left River unable to onboard
/// people. Benefits over MCP: one tool schema instead of ~50, no subset-drift,
/// and the complete CLI capability set (plus self-discovery via `--help`).
///
/// SECURITY — this is NOT a general shell:
///   * Only the `kan` and `outline` CLIs can be invoked (fixed allowlist;
///     anything else is refused).
///   * Args are passed as an argv list to `node` with `runInShell: false`, so
///     shell metacharacters are never interpreted — no command injection from
///     a crafted chat message.
///   * Destructive / structural subcommands (delete-board, remove-member,
///     create/rotate invite link, collection mutations, permanent deletes)
///     require the *message sender* to be an admin. Everyone else is refused.
///     This preserves the per-tool admin gating the MCP path enforced, while
///     still letting any member create/edit/delete cards and docs.
library;

import 'dart:convert';
import 'dart:io';

import '../agent/tool_registry.dart';

/// Directory holding the vendored CLI `.mjs` files. Overridable via
/// `CLI_TOOLS_DIR` so the same code works from the repo root (`cli-tools`)
/// and from `/app/cli-tools` in the container.
String get _cliDir =>
    Platform.environment['CLI_TOOLS_DIR'] ?? 'cli-tools';

/// Kan subcommands that restructure shared scaffolding or rotate access.
/// Note: `delete-card` is intentionally NOT here — any member may delete cards.
const _kanAdminSubcommands = <String>{
  'delete-board',
  'delete-list',
  'delete-label',
  'remove-member',
  'update-member-role',
  'create-invite-link',
  'deactivate-invite-link',
};

/// Outline subcommands that restructure shared scaffolding.
/// Note: `documents.delete` (to trash) is allowed for everyone; only the
/// `--permanent` variant is gated (see [_requiresAdmin]).
const _outlineAdminSubcommands = <String>{
  'collections.create',
  'collections.update',
  'collections.delete',
};

/// Whether [subcommand] of [tool] (with [args]) needs an admin sender.
bool _requiresAdmin(String tool, String subcommand, List<String> args) {
  if (tool == 'kan' && _kanAdminSubcommands.contains(subcommand)) return true;
  if (tool == 'outline' && _outlineAdminSubcommands.contains(subcommand)) {
    return true;
  }
  // Permanent (trash-bypassing) document deletion is irreversible — admin only.
  if (tool == 'outline' &&
      subcommand == 'documents.delete' &&
      args.contains('--permanent')) {
    return true;
  }
  return false;
}

/// Registers the `run_cli` executor tool.
///
/// [kanApiKey] / [kanBaseUrl] and [outlineApiKey] / [outlineBaseUrl] are the
/// bot's credentials; they're injected into the CLI subprocess environment.
/// Pass `null` for a service that isn't configured — its subcommands will then
/// fail with a clear "not configured" error rather than hitting a default host.
void registerCliTools(
  ToolRegistry registry, {
  String? kanApiKey,
  String? kanBaseUrl,
  String? outlineApiKey,
  String? outlineBaseUrl,
}) {
  registry.registerCustomTool(
    CustomToolDef(
      name: 'run_cli',
      description: _description,
      inputSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'tool': <String, dynamic>{
            'type': 'string',
            'enum': <String>['kan', 'outline'],
            'description': 'Which CLI to run.',
          },
          'args': <String, dynamic>{
            'type': 'array',
            'items': <String, dynamic>{'type': 'string'},
            'description':
                'Subcommand and flags as an argv list, e.g. '
                    '["create-card","--list-id","abc123def456","--title",'
                    '"Plan the offsite"]. Each flag and each value is its own '
                    'array element; values may contain spaces. Pass '
                    '["<subcommand>","--help"] to discover a subcommand\'s '
                    'flags.',
          },
        },
        'required': <String>['tool', 'args'],
      },
      // Gating is per-subcommand inside the handler, not all-or-nothing.
      requiresAdmin: false,
      handler: (args) => _runCli(
        registry,
        args,
        kanApiKey: kanApiKey,
        kanBaseUrl: kanBaseUrl,
        outlineApiKey: outlineApiKey,
        outlineBaseUrl: outlineBaseUrl,
      ),
    ),
  );
}

Future<String> _runCli(
  ToolRegistry registry,
  Map<String, dynamic> args, {
  String? kanApiKey,
  String? kanBaseUrl,
  String? outlineApiKey,
  String? outlineBaseUrl,
}) async {
  final tool = args['tool'] as String?;
  if (tool != 'kan' && tool != 'outline') {
    return _err('Unknown tool: ${tool ?? "(null)"}. Allowed: kan, outline.');
  }

  final rawArgs = args['args'];
  if (rawArgs is! List || rawArgs.isEmpty) {
    return _err('`args` must be a non-empty array, e.g. ["list-workspaces"].');
  }
  final cliArgs = rawArgs.map((e) => e.toString()).toList();
  final subcommand = cliArgs.first;

  // --- Admin gate (per-subcommand) ---
  // `tool` is guaranteed "kan" or "outline" by the guard above; the `!`
  // satisfies the analyzer (equality-with-literal doesn't promote nullability).
  if (_requiresAdmin(tool!, subcommand, cliArgs) &&
      !(registry.context?.isAdmin ?? false)) {
    return jsonEncode(<String, dynamic>{
      'error': 'This action requires admin privileges.',
      'tool': tool,
      'subcommand': subcommand,
    });
  }

  // --- Credentials → CLI environment ---
  final env = <String, String>{};
  if (tool == 'kan') {
    if (kanApiKey == null || kanBaseUrl == null) {
      return _err('Kan is not configured (missing KAN_API_KEY/KAN_BASE_URL).');
    }
    env['KAN_API_KEY'] = kanApiKey;
    env['KAN_BASE_URL'] = kanBaseUrl;
  } else {
    if (outlineApiKey == null || outlineBaseUrl == null) {
      return _err(
          'Outline is not configured (missing OUTLINE_API_KEY/OUTLINE_BASE_URL).');
    }
    env['OUTLINE_API_KEY'] = outlineApiKey;
    // The outline CLI reads OUTLINE_API_URL, not OUTLINE_BASE_URL.
    env['OUTLINE_API_URL'] = outlineBaseUrl;
  }

  final cliPath = '$_cliDir/$tool.mjs';

  // runInShell:false → argv is passed verbatim, no shell parsing/injection.
  // includeParentEnvironment defaults to true so PATH/node resolution works.
  final ProcessResult result;
  try {
    result = await Process.run(
      'node',
      <String>[cliPath, ...cliArgs],
      environment: env,
      runInShell: false,
    ).timeout(const Duration(seconds: 30));
  } on ProcessException catch (e) {
    return _err('Failed to launch CLI: ${e.message}');
  } catch (e) {
    return _err('CLI did not complete in time or errored: $e');
  }

  final out = (result.stdout as String).trim();
  final errOut = (result.stderr as String).trim();

  if (result.exitCode != 0) {
    return jsonEncode(<String, dynamic>{
      'error': 'CLI exited with code ${result.exitCode}',
      'tool': tool,
      'subcommand': subcommand,
      if (errOut.isNotEmpty) 'stderr': errOut,
      if (out.isNotEmpty) 'stdout': out,
    });
  }

  if (out.isEmpty) {
    return jsonEncode(<String, dynamic>{
      'ok': true,
      if (errOut.isNotEmpty) 'note': errOut,
    });
  }
  return out;
}

String _err(String message) =>
    jsonEncode(<String, dynamic>{'error': message});

/// Tool description, including the available subcommands so the model can pick
/// without a round-trip. Kept compact; the model can run `["<cmd>","--help"]`
/// for a subcommand's exact flags.
const _description = '''
Run the Kan.bn (project boards/cards) or Outline (wiki docs) CLI. This is the
single tool for all Kan and Outline work — onboarding people, and creating,
reading, editing, and deleting cards and documents.

Pass `tool` ("kan" or "outline") and `args` (the subcommand + flags as an argv
array). Output is JSON on stdout. Run ["<subcommand>","--help"] to see a
subcommand's flags.

ONBOARDING (people asking to join):
  - Kan: ["get-invite-link","--workspace-id","<id>"] returns a shareable link
    anyone can use to join as a member (members can fully edit/delete cards).
    If none is active, an admin can ["create-invite-link","--workspace-id",
    "<id>"] (this ROTATES the link — invalidates the old one; ~7-day expiry).
  - Outline has NO shareable link. Collect the person's email PRIVATELY (in a
    DM, never a public channel), then ["users.invite","--email","x@y.com",
    "--name","Their Name"] emails them a sign-in link; they join as a member.

KAN subcommands: list-workspaces, get-workspace, search, list-members,
invite-member, remove-member*, update-member-role*, get-invite-link,
create-invite-link*, deactivate-invite-link*, get-invite, accept-invite,
list-boards, get-board, create-board, update-board, delete-board*,
create-list, update-list, delete-list*, create-card, get-card, update-card,
delete-card, toggle-card-label, toggle-card-member, add-comment, create-label,
update-label, delete-label*, create-checklist, add-checklist-item,
update-checklist-item, delete-checklist.

OUTLINE subcommands: auth, collections.list, collections.info,
collections.create*, collections.update*, collections.delete*, documents.list,
documents.info, documents.search, documents.create, documents.update,
documents.move, documents.archive, documents.unarchive, documents.delete
(add --permanent to bypass trash*), documents.drafts, documents.export,
users.list, users.invite, raw (--verb foo.bar --body '{...}').

Subcommands marked * require the requester to be an admin; everyone else may
read, create, edit, comment, and delete cards/documents.
''';
