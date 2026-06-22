/// `capture_lore` — River's proactive memory of the community's stories.
///
/// The Imagineering/hackerspace community is rich with durable lore: origin
/// stories, principles, who-knows-whom, the backstory of a project or a name.
/// River *sees* all of it (it reads every group message) but its `[skip]`
/// heuristic — the thing that stops it butting into side conversations — is
/// exactly what silenced it on lore. This tool gives River a way to quietly
/// SAVE a story without having to reply to it.
///
/// River already has full Outline write access via `run_cli`, so this tool is
/// not about *capability* — it's about three things `run_cli` can't give
/// cleanly:
///   1. **Dedup** — `run_cli` has no memory, so the same story would be
///      re-appended every time it resurfaces. This tool dedups via
///      `bot_metadata` keyed `lore::<chatId>::<key>` (mirrors the nudge dedup
///      at `scheduler.dart`).
///   2. **Append semantics** — Outline's `documents.update` replaces the whole
///      body; appending the naive way needs a read-modify-write the model
///      shouldn't orchestrate per call. The vendored `outline` CLI exposes
///      `documents.update --append` (server-side append), so this tool just
///      hands it the new block.
///   3. **A single tool call** — `capture_lore(summary, key)` instead of the
///      model wiring up a read + an update by hand.
///
/// Transaction boundary: the dedup marker is written ONLY after the append
/// succeeds. A failed append therefore leaves the lore *retryable* rather than
/// silently deduped into oblivion (the "durable side-effect before the marker"
/// rule).
library;

import 'dart:convert';
import 'dart:io';

import '../agent/tool_registry.dart';
import '../db/queries.dart';
import 'cli_tools.dart' show execVendoredCli;

/// Outline document id of the **Lore Inbox** — the append target for raw lore
/// captures (curated later into topic docs in the `Lore` collection).
/// Overridable via `LORE_INBOX_DOC_ID` for a different instance or for tests.
String get _loreInboxDocId =>
    Platform.environment['LORE_INBOX_DOC_ID'] ??
    '4db30373-4c22-4539-b62a-222a25e730d0';

/// Registers the `capture_lore` tool with the [ToolRegistry].
///
/// [outlineApiKey] / [outlineBaseUrl] are the bot's Outline credentials,
/// injected into the CLI subprocess environment. Pass `null` for an
/// unconfigured Outline — the tool registers but returns a clear "not
/// configured" error when invoked.
void registerLoreTools(
  ToolRegistry registry,
  Queries queries, {
  String? outlineApiKey,
  String? outlineBaseUrl,
}) {
  registry.registerCustomTool(
    _captureLoreToolDef(registry, queries, outlineApiKey, outlineBaseUrl),
  );
}

CustomToolDef _captureLoreToolDef(
  ToolRegistry registry,
  Queries queries,
  String? outlineApiKey,
  String? outlineBaseUrl,
) {
  return CustomToolDef(
    name: 'capture_lore',
    description: _description,
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'summary': <String, dynamic>{
          'type': 'string',
          'description': 'The lore to keep, written as Markdown in your own '
              'words — an origin story, a principle, a piece of '
              'hackerspace/AI history, who-knows-whom, a project backstory. '
              'Link any person who has a People-collection node as '
              '`[Name](/doc/slug)` so Outline auto-builds the backlink graph. '
              'If you do not know a person\'s doc slug, use their plain name. '
              'NEVER capture personal/sensitive material (mental health, '
              'dates, interpersonal conflict) — that is not lore.',
        },
        'key': <String, dynamic>{
          'type': 'string',
          'description': 'A short, stable kebab-case slug identifying THIS '
              'piece of lore, e.g. "cray-supercomputer-stories" or '
              '"the-dawn-gate-origin". Used to dedup — the same key is only '
              'captured once per chat, so reuse the same slug if the same '
              'story resurfaces.',
        },
        'title': <String, dynamic>{
          'type': 'string',
          'description': 'Optional short heading for the capture (defaults to '
              'the key). Shown as a `##` heading in the Lore Inbox.',
        },
      },
      'required': <String>['summary', 'key'],
    },
    handler: (args) => _captureLore(
      registry,
      queries,
      args,
      outlineApiKey: outlineApiKey,
      outlineBaseUrl: outlineBaseUrl,
    ),
  );
}

Future<String> _captureLore(
  ToolRegistry registry,
  Queries queries,
  Map<String, dynamic> args, {
  String? outlineApiKey,
  String? outlineBaseUrl,
}) async {
  final summary = (args['summary'] as String?)?.trim() ?? '';
  if (summary.isEmpty) {
    return _err('`summary` is empty — nothing to capture.');
  }
  final key = (args['key'] as String?)?.trim() ?? '';
  if (key.isEmpty) {
    return _err(
        '`key` is required — a short stable kebab-case slug for dedup.');
  }
  final title = (args['title'] as String?)?.trim();

  if (outlineApiKey == null || outlineBaseUrl == null) {
    return _err(
        'Outline is not configured (missing OUTLINE_API_KEY/OUTLINE_BASE_URL).');
  }

  final ctx = registry.context;
  final chatId = ctx?.chatId ?? 'unknown';

  // --- Dedup (before any side-effect) ---
  final dedupKey = 'lore::$chatId::$key';
  if (queries.getMetadata(dedupKey) != null) {
    return jsonEncode(<String, dynamic>{
      'skipped': 'already captured',
      'key': key,
    });
  }

  // --- Build the append block ---
  final heading = (title != null && title.isNotEmpty) ? title : key;
  final capturedAt = DateTime.now().toUtc().toIso8601String();
  final block = StringBuffer()
    ..writeln()
    ..writeln('## $heading')
    ..writeln()
    ..writeln(summary)
    ..writeln()
    ..writeln('_— captured ${capturedAt.split('T').first}_')
    ..writeln();

  // --- Durable side-effect: server-side append to the Lore Inbox ---
  final env = <String, String>{
    'PATH': Platform.environment['PATH'] ?? '/usr/local/bin:/usr/bin:/bin',
    'OUTLINE_API_KEY': outlineApiKey,
    // The outline CLI reads OUTLINE_API_URL, not OUTLINE_BASE_URL.
    'OUTLINE_API_URL': outlineBaseUrl,
  };

  final result = await execVendoredCli(
    tool: 'outline',
    args: <String>[
      'documents.update',
      '--id',
      _loreInboxDocId,
      '--text',
      block.toString(),
      '--append',
    ],
    env: env,
  );

  if (result.exitCode != 0) {
    return jsonEncode(<String, dynamic>{
      'error': 'Failed to append lore to the Lore Inbox.',
      if (result.stderr.isNotEmpty) 'stderr': result.stderr,
      if (result.stdout.isNotEmpty) 'stdout': result.stdout,
    });
  }

  // --- Mark captured ONLY after the append succeeded ---
  // A failed append above returns early WITHOUT setting this marker, so the
  // lore stays retryable rather than being silently deduped away.
  queries.setMetadata(dedupKey, capturedAt);

  return jsonEncode(<String, dynamic>{
    'captured': true,
    'key': key,
    'doc_id': _loreInboxDocId,
  });
}

String _err(String message) => jsonEncode(<String, dynamic>{'error': message});

const _description = '''
Quietly save a durable piece of community lore to the Lore Inbox (an Outline
doc), without replying in chat. Use this when you notice a story worth keeping:
an origin story, a guiding principle, a piece of hackerspace/AI history, a
who-knows-whom connection, the backstory of a project or a name.

Capture is SILENT — after calling this, if no one addressed you, reply with
exactly `[skip]`. Do not announce that you saved something unless asked. This is
how you build the community's memory without butting into side conversations.

Pass `summary` (the lore, as Markdown, person names linked `[Name](/doc/slug)`)
and `key` (a stable kebab-case slug so the same story is captured only once).

NEVER capture personal or sensitive material — mental-health talk, dates,
interpersonal conflict. That is not lore; extract only community/project facts.
''';
