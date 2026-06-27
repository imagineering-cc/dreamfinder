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
/// SECURITY MODEL — these CLIs were written for a trusted developer at a
/// terminal; exposing them to an autonomous bot that reads a semi-public chat
/// widens the trust boundary, so the executor clamps the surface to "edit
/// cards/docs + onboard" with **default-deny** posture:
///
///   1. Fixed CLI allowlist — only `kan` and `outline` (anything else refused).
///   2. argv passed with `runInShell: false` → no shell metacharacter
///      interpretation, so no *command* injection from a crafted message.
///   3. Forbidden flags ([_forbiddenFlags]) are rejected outright regardless of
///      role — they grant capabilities beyond "edit content":
///        * `--text-file` reads an ARBITRARY local file (e.g.
///          `/proc/self/environ`, `/app/.env`) and would let a chat member
///          exfiltrate secrets into a wiki doc. The bot passes content inline
///          via `--text`, so this is pure attack surface.
///        * `--site` selects a *different* credential set from the
///          environment, sidestepping the creds this executor injects.
///   4. Minimal child environment ([Process.start] with
///      `includeParentEnvironment: false`): the subprocess sees ONLY `PATH`
///      plus the one service's creds — never DF's Anthropic key, Matrix token,
///      or any other secret. Defence-in-depth behind rule 3.
///   5. Per-subcommand admin gate ([_requiresAdmin]): destructive/structural
///      ops, the `raw` escape hatch, role-escalating invites, and permanent
///      deletes require the *message sender* to be an admin. Everyone else may
///      still read, create/edit/delete cards & docs, comment, and onboard
///      members. This preserves (and tightens) the gating the MCP path had.
///   6. Timeout that actually KILLS the child ([Process.start] + `kill`), so a
///      hung CLI can't orphan a `node` process holding a socket open.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../agent/tool_registry.dart';

/// Directory holding the vendored CLI `.mjs` files. Overridable via
/// `CLI_TOOLS_DIR` so the same code works from the repo root (`cli-tools`)
/// and from `/app/cli-tools` in the container.
String get _cliDir => Platform.environment['CLI_TOOLS_DIR'] ?? 'cli-tools';

/// Flags that are never permitted from a chat-originated call, for ANY sender.
/// They expose capabilities beyond editing content (arbitrary file reads /
/// alternate credential selection). Matched as both `--flag` and `--flag=value`
/// forms (node's `parseArgs` accepts both). See the SECURITY MODEL note.
const _forbiddenFlags = <String>{'--text-file', '--site'};

/// Kan subcommands that restructure shared scaffolding, manage membership, or
/// rotate access. Everything NOT listed (card create/update/delete, comments,
/// checklists, label toggles, get-invite-link, invite-member, list create/
/// update) is available to any member — that's the "everyone can edit/delete
/// cards" policy. `delete-card` is deliberately absent: members may delete
/// cards.
const _kanAdminSubcommands = <String>{
  'create-board',
  'update-board',
  'delete-board',
  'delete-list',
  'delete-label',
  'remove-member',
  'update-member-role',
  'create-invite-link',
  'deactivate-invite-link',
};

/// Outline subcommands that restructure shared scaffolding or wield raw API
/// power. Document create/update/delete-to-trash, archive/unarchive, move,
/// comments, and member-role invites stay available to any member.
const _outlineAdminSubcommands = <String>{
  'collections.create',
  'collections.update',
  'collections.delete',
  // `raw` can call ANY Outline verb (incl. collections.delete, user role
  // changes) — gating the named verbs is meaningless unless raw is gated too.
  'raw',
};

/// Radicale subcommands that WRITE to the shared calendar / address book.
/// Reads (list-calendars, list-events, get-event, list-address-books,
/// list-contacts, get-contact) stay open to any member; mutating the team
/// calendar or contacts (creating/deleting events & contacts, creating
/// calendars & address books) is admin-gated to match the "everyone reads,
/// admins restructure" posture.
const _radicaleAdminSubcommands = <String>{
  // Calendar (CalDAV) writes.
  'add-event',
  'delete-event',
  'mkcalendar',
  // Contacts (CardDAV) writes.
  'mkaddressbook',
  'add-contact',
  'update-contact',
  'delete-contact',
};

/// True if [args] requests a `--user` other than [selfUser] (the configured
/// Radicale principal). Used to admin-gate cross-principal collection
/// enumeration: omitting `--user` (or naming yourself) is open; naming someone
/// else reaches through River's shared credentials into their collections.
bool _crossPrincipalUser(List<String> args, String? selfUser) {
  // Match the vendored CLI's own argv grammar: Node `parseArgs` accepts BOTH
  // `--user value` and `--user=value`, and on a repeated flag the LAST value
  // wins. A guard that only saw `--user value` (or only the first occurrence)
  // would be bypassed by `--user=other` or `--user me --user other`. Gate if
  // ANY occurrence names someone other than the configured principal — same
  // both-forms shape as [_invitesAdminRole] (Carnot, cage-match PR #115 r5).
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    String? value;
    if (a == '--user' && i + 1 < args.length) {
      value = args[i + 1];
    } else if (a.startsWith('--user=')) {
      value = a.substring('--user='.length);
    }
    if (value != null && value != selfUser) return true;
  }
  return false;
}

/// True if [args] sets an elevated invite role (`--role admin`). Onboarding a
/// plain member is open; minting an admin is not.
bool _invitesAdminRole(List<String> args) {
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--role' && i + 1 < args.length) {
      return args[i + 1].toLowerCase() == 'admin';
    }
    if (a.toLowerCase().startsWith('--role=')) {
      return a.substring('--role='.length).toLowerCase() == 'admin';
    }
  }
  return false;
}

/// Whether [subcommand] of [tool] (with [args]) needs an admin sender.
bool _requiresAdmin(String tool, String subcommand, List<String> args) {
  if (tool == 'kan' && _kanAdminSubcommands.contains(subcommand)) return true;
  if (tool == 'radicale' && _radicaleAdminSubcommands.contains(subcommand)) {
    return true;
  }
  if (tool == 'outline') {
    if (_outlineAdminSubcommands.contains(subcommand)) return true;
    // Permanent (trash-bypassing) deletion is irreversible — admin only.
    if (subcommand == 'documents.delete' && args.contains('--permanent')) {
      return true;
    }
    // Inviting someone as an *admin* is privilege-granting — admin only.
    // (Inviting a member is open, for self-service onboarding.)
    if (subcommand == 'users.invite' && _invitesAdminRole(args)) return true;
  }
  // kan invites also carry roles via update-member-role (already gated above);
  // invite-member has no role flag, so member invites stay open.
  return false;
}

/// Returns the matched forbidden flag in [args], or null if none.
String? _forbiddenFlagIn(List<String> args) {
  for (final a in args) {
    for (final f in _forbiddenFlags) {
      if (a == f || a.startsWith('$f=')) return f;
    }
  }
  return null;
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
  String? radicaleBaseUrl,
  String? radicaleUsername,
  String? radicalePassword,
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
            'enum': <String>['kan', 'outline', 'radicale'],
            'description': 'Which CLI to run.',
          },
          'args': <String, dynamic>{
            'type': 'array',
            'items': <String, dynamic>{'type': 'string'},
            'description': 'Subcommand and flags as an argv list, e.g. '
                '["create-card","--list-id","abc123def456","--title",'
                '"Plan the offsite"] or '
                '["list-events","--calendar","nick/imagineering-events"]. '
                'Each flag and each value is its own array element; values may '
                'contain spaces. Pass ["<subcommand>","--help"] to discover a '
                'subcommand\'s flags.',
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
        radicaleBaseUrl: radicaleBaseUrl,
        radicaleUsername: radicaleUsername,
        radicalePassword: radicalePassword,
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
  String? radicaleBaseUrl,
  String? radicaleUsername,
  String? radicalePassword,
}) async {
  final tool = args['tool'] as String?;
  if (tool != 'kan' && tool != 'outline' && tool != 'radicale') {
    return _err(
        'Unknown tool: ${tool ?? "(null)"}. Allowed: kan, outline, radicale.');
  }

  final rawArgs = args['args'];
  if (rawArgs is! List || rawArgs.isEmpty) {
    return _err('`args` must be a non-empty array, e.g. ["list-workspaces"].');
  }
  // Require genuine strings — silently stringifying maps/lists/bools would
  // muddy the argv contract and could smuggle unexpected shapes to the CLI.
  final cliArgs = <String>[];
  for (final e in rawArgs) {
    if (e is! String) {
      return _err('Every element of `args` must be a string; got '
          '${e.runtimeType} ("$e"). Pass each flag and value as its own '
          'string.');
    }
    cliArgs.add(e);
  }
  final subcommand = cliArgs.first;

  // --- Forbidden-flag screen (applies to every sender) ---
  final forbidden = _forbiddenFlagIn(cliArgs);
  if (forbidden != null) {
    return _err('The `$forbidden` flag is not permitted via run_cli. '
        'Pass document content inline with --text, and never select an '
        'alternate --site.');
  }

  // --- Admin gate (per-subcommand) ---
  // `tool` is guaranteed "kan", "outline", or "radicale" by the guard above;
  // the `!` satisfies the analyzer (equality-with-literal doesn't promote
  // nullability).
  if (_requiresAdmin(tool!, subcommand, cliArgs) &&
      !(registry.context?.isAdmin ?? false)) {
    return jsonEncode(<String, dynamic>{
      'error': 'This action requires admin privileges.',
      'tool': tool,
      'subcommand': subcommand,
    });
  }

  // --- Cross-principal enumeration gate (radicale) ---
  // `list-calendars`/`list-address-books` default to River's own principal, but
  // `--user <other>` enumerates ANOTHER principal's collections through River's
  // shared Radicale credentials (which can read /nick/). The known-path content
  // reads (`list-events --calendar nick/imagineering-events`) stay open by
  // design — this only gates the *discovery* of someone else's collections to
  // admins (Carnot, cage-match PR #115 r4).
  if (tool == 'radicale' &&
      (subcommand == 'list-calendars' ||
          subcommand == 'list-address-books') &&
      _crossPrincipalUser(cliArgs, radicaleUsername) &&
      !(registry.context?.isAdmin ?? false)) {
    return jsonEncode(<String, dynamic>{
      'error': 'Listing another principal\'s collections requires admin '
          'privileges. Omit --user to list your own.',
      'tool': tool,
      'subcommand': subcommand,
    });
  }

  // --- Credentials → minimal CLI environment ---
  // includeParentEnvironment:false (below) means we must supply PATH so `node`
  // resolves; PATH isn't secret. The child sees ONLY this map — no inherited
  // DF secrets, no per-site creds.
  final env = <String, String>{
    'PATH': Platform.environment['PATH'] ?? '/usr/local/bin:/usr/bin:/bin',
  };
  if (tool == 'kan') {
    if (kanApiKey == null || kanBaseUrl == null) {
      return _err('Kan is not configured (missing KAN_API_KEY/KAN_BASE_URL).');
    }
    env['KAN_API_KEY'] = kanApiKey;
    env['KAN_BASE_URL'] = kanBaseUrl;
  } else if (tool == 'outline') {
    if (outlineApiKey == null || outlineBaseUrl == null) {
      return _err(
          'Outline is not configured (missing OUTLINE_API_KEY/OUTLINE_BASE_URL).');
    }
    env['OUTLINE_API_KEY'] = outlineApiKey;
    // The outline CLI reads OUTLINE_API_URL, not OUTLINE_BASE_URL.
    env['OUTLINE_API_URL'] = outlineBaseUrl;
  } else {
    // tool == 'radicale'
    if (radicaleBaseUrl == null ||
        radicaleUsername == null ||
        radicalePassword == null) {
      return _err('Radicale is not configured (missing RADICALE_BASE_URL/'
          'RADICALE_USERNAME/RADICALE_PASSWORD).');
    }
    env['RADICALE_BASE_URL'] = radicaleBaseUrl;
    env['RADICALE_USERNAME'] = radicaleUsername;
    env['RADICALE_PASSWORD'] = radicalePassword;
  }

  final outcome = await execVendoredCli(tool: tool, args: cliArgs, env: env);

  switch (outcome) {
    case CliLaunchFailure(:final message):
      return _err(message);
    case CliTimeout():
      return _err('CLI timed out after 30s and was killed.');
    case CliCompleted(:final exitCode, :final stdout, :final stderr):
      if (exitCode != 0) {
        return jsonEncode(<String, dynamic>{
          'error': 'CLI exited with code $exitCode',
          'tool': tool,
          'subcommand': subcommand,
          if (stderr.isNotEmpty) 'stderr': stderr,
          if (stdout.isNotEmpty) 'stdout': stdout,
        });
      }
      if (stdout.isEmpty) {
        return jsonEncode(<String, dynamic>{
          'ok': true,
          if (stderr.isNotEmpty) 'note': stderr,
        });
      }
      return stdout;
  }
}

/// Outcome of a vendored-CLI subprocess. A sealed hierarchy rather than an
/// `(int exitCode, …)` record so the two failures that never produce a real
/// exit code — launch failure and timeout-kill — are *distinct types*, not
/// magic negative codes that could collide with a signal-killed child's own
/// negative exit code (e.g. SIGHUP→-1, SIGINT→-2).
sealed class CliOutcome {
  const CliOutcome();
}

/// The CLI ran to completion (possibly with a non-zero [exitCode]). [stdout]
/// and [stderr] are drained and trimmed.
class CliCompleted extends CliOutcome {
  const CliCompleted({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

/// `node` could not be spawned (e.g. not on PATH). [message] explains why.
class CliLaunchFailure extends CliOutcome {
  const CliLaunchFailure(this.message);

  final String message;
}

/// The CLI exceeded the 30s budget and was killed.
class CliTimeout extends CliOutcome {
  const CliTimeout();
}

/// Launches a vendored CLI (`<CLI_TOOLS_DIR>/<tool>.mjs`) with [args] and a
/// minimal [env], returning a [CliOutcome]. This is the ONE hardened launch
/// path shared by every caller (`run_cli`, `capture_lore`):
///
///   * `includeParentEnvironment: false` — the child sees ONLY [env]; no
///     inherited DF secrets (Anthropic key, Matrix token, …). Callers must
///     supply `PATH` plus exactly the one service's creds.
///   * `runInShell: false` — argv is passed verbatim, so no shell metacharacter
///     interpretation and thus no command injection from crafted content.
///   * 30s timeout that actually KILLS the child (`Process.start` + `kill`),
///     so a hung `node` can't orphan a process holding a socket open.
///
/// Returns [CliCompleted] when the process ran (inspect its `exitCode`),
/// [CliLaunchFailure] when `node` couldn't be spawned, or [CliTimeout] on the
/// timeout-kill. Callers `switch` on the result and decide how to present it.
Future<CliOutcome> execVendoredCli({
  required String tool,
  required List<String> args,
  required Map<String, String> env,
}) async {
  final cliPath = '$_cliDir/$tool.mjs';

  // Process.start (not Process.run) so we hold a handle and can actually KILL
  // a hung child on timeout — Future.timeout alone would orphan the node
  // process.
  final Process proc;
  try {
    proc = await Process.start(
      'node',
      <String>[cliPath, ...args],
      environment: env,
      includeParentEnvironment: false,
      runInShell: false,
    );
  } on ProcessException catch (e) {
    return CliLaunchFailure('Failed to launch CLI: ${e.message}');
  }

  // Drain stdout/stderr concurrently with the exit wait to avoid pipe-buffer
  // deadlock on large output.
  final stdoutFuture = proc.stdout.transform(utf8.decoder).join();
  final stderrFuture = proc.stderr.transform(utf8.decoder).join();

  final int exitCode;
  try {
    exitCode = await proc.exitCode.timeout(const Duration(seconds: 30));
  } on TimeoutException {
    proc.kill(ProcessSignal.sigkill);
    // Let the streams close out so we don't leak subscriptions.
    unawaited(stdoutFuture.catchError((_) => ''));
    unawaited(stderrFuture.catchError((_) => ''));
    return const CliTimeout();
  }

  return CliCompleted(
    exitCode: exitCode,
    stdout: (await stdoutFuture).trim(),
    stderr: (await stderrFuture).trim(),
  );
}

String _err(String message) => jsonEncode(<String, dynamic>{'error': message});

/// Tool description, including the available subcommands so the model can pick
/// without a round-trip. Kept compact; the model can run `["<cmd>","--help"]`
/// for a subcommand's exact flags.
const _description = '''
Run the Kan.bn (project boards/cards), Outline (wiki docs), or Radicale
(CalDAV calendar events + CardDAV contacts) CLI. This is the single tool for
all Kan, Outline, calendar, and contacts work — onboarding people,
creating/reading/editing/deleting cards and documents, and reading/managing
calendar events and contacts.

Pass `tool` ("kan", "outline", or "radicale") and `args` (the subcommand +
flags as an argv array of strings). Output is JSON on stdout. Run
["<subcommand>","--help"] to see a subcommand's flags. The --text-file and
--site flags are disabled.

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
list-boards, get-board, create-board*, update-board*, delete-board*,
create-list, update-list, delete-list*, create-card, get-card, update-card,
delete-card, toggle-card-label, toggle-card-member, add-comment, create-label,
update-label, delete-label*, create-checklist, add-checklist-item,
update-checklist-item, delete-checklist.

OUTLINE subcommands: auth, collections.list, collections.info,
collections.create*, collections.update*, collections.delete*, documents.list,
documents.info, documents.search, documents.create, documents.update,
documents.move, documents.archive, documents.unarchive, documents.delete
(add --permanent to bypass trash*), documents.drafts, documents.export,
users.list, users.invite (--role admin requires admin*).

RADICALE subcommands — calendar events (CalDAV): list-calendars, list-events
(e.g. ["list-events","--calendar","nick/imagineering-events","--from","<ISO>",
"--to","<ISO>"] — recurrence + timezones are expanded server-side, output is
JSON in UTC), get-event, add-event*, delete-event*, mkcalendar*. --calendar
accepts a full URL or a "<user>/<calendar>" path.

RADICALE subcommands — contacts (CardDAV): list-address-books, list-contacts
(["list-contacts","--addressbook","<path>"]), get-contact, mkaddressbook*,
add-contact* (--fn <full name> [--email --tel --org --title --note --uid]),
update-contact* (same flags; --uid identifies the card), delete-contact*.
--addressbook accepts a full URL or a "<user>/<addressbook>" path.

Subcommands marked * require the requester to be an admin; everyone else may
read, create, edit, comment, and delete cards/documents, and onboard members.
The Outline `raw` verb is admin-only (it can call any API endpoint).
''';
