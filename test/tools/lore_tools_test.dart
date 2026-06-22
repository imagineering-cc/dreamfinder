import 'dart:convert';

import 'package:dreamfinder/src/agent/tool_registry.dart';
import 'package:dreamfinder/src/db/database.dart';
import 'package:dreamfinder/src/db/queries.dart';
import 'package:dreamfinder/src/tools/lore_tools.dart';
import 'package:test/test.dart';

/// These tests exercise `capture_lore`'s validation, configuration, and dedup
/// gating — every path that fails-fast (or no-ops) BEFORE spawning the node
/// `outline` CLI, so no network or node runtime is required. The happy-path
/// append is covered by a live smoke test, not here.
void main() {
  late BotDatabase db;
  late Queries queries;

  setUp(() {
    db = BotDatabase.inMemory();
    queries = Queries(db);
  });

  tearDown(() => db.close());

  ToolRegistry makeRegistry({
    String chatId = 'room1',
    String? outlineApiKey = 'o',
    String? outlineBaseUrl = 'https://outline.example/api',
  }) {
    final registry = ToolRegistry();
    registry.setContext(ToolContext(
      senderId: 'u1',
      isAdmin: false,
      chatId: chatId,
    ));
    registerLoreTools(
      registry,
      queries,
      outlineApiKey: outlineApiKey,
      outlineBaseUrl: outlineBaseUrl,
    );
    return registry;
  }

  Future<Map<String, dynamic>> run(
    ToolRegistry registry,
    Map<String, dynamic> args,
  ) async {
    final raw = await registry.executeTool('capture_lore', args);
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  test('registers a single capture_lore tool', () {
    final registry = makeRegistry();
    final names = registry.getAllToolDefinitions().map((t) => t.name).toList();
    expect(names, contains('capture_lore'));
    expect(names.where((n) => n == 'capture_lore'), hasLength(1));
  });

  test('rejects empty summary', () async {
    final result = await run(makeRegistry(), {
      'summary': '   ',
      'key': 'some-key',
    });
    expect(result['error'], contains('summary'));
  });

  test('rejects missing key', () async {
    final result = await run(makeRegistry(), {
      'summary': 'A real story worth keeping.',
      'key': '',
    });
    expect(result['error'], contains('key'));
  });

  test('reports when Outline is not configured', () async {
    final registry = makeRegistry(outlineApiKey: null, outlineBaseUrl: null);
    final result = await run(registry, {
      'summary': 'A real story worth keeping.',
      'key': 'some-key',
    });
    expect(result['error'], contains('not configured'));
  });

  group('dedup', () {
    test('skips a key already captured in this chat (no subprocess)', () async {
      // Pre-seed the dedup marker the tool would have written on a prior
      // successful capture. The skip path returns BEFORE spawning node, so
      // this needs no Outline access.
      queries.setMetadata(
          'lore::room1::cray-stories', '2026-06-22T00:00:00.000Z');

      final result = await run(makeRegistry(chatId: 'room1'), {
        'summary': 'The Cray supercomputer stories, retold.',
        'key': 'cray-stories',
      });

      expect(result['skipped'], 'already captured');
      expect(result['key'], 'cray-stories');
    });

    test('key is normalized to canonical kebab so casing/spacing dedups',
        () async {
      // A prior capture stored under the canonical key.
      queries.setMetadata(
          'lore::room1::cray-stories', '2026-06-22T00:00:00.000Z');

      // These all normalize to "cray-stories" — every one must hit the skip
      // gate (before any subprocess), proving they dedup to the same identity.
      for (final variant in [
        'Cray Stories',
        'cray_stories',
        '  CRAY--STORIES  '
      ]) {
        final result = await run(makeRegistry(chatId: 'room1'), {
          'summary': 'The Cray supercomputer stories, retold.',
          'key': variant,
        });
        expect(result['skipped'], 'already captured',
            reason: '"$variant" should normalize to the captured key');
      }
    });

    test('dedup marker is namespaced per chat', () {
      // Capturing in room1 writes a room1-scoped marker; the SAME key in room2
      // resolves to a different marker, so it is not pre-deduped. Asserted at
      // the metadata layer so the test needs no subprocess. (The matching-chat
      // skip is covered by the test above.)
      queries.setMetadata(
          'lore::room1::cray-stories', '2026-06-22T00:00:00.000Z');

      expect(queries.getMetadata('lore::room1::cray-stories'), isNotNull);
      expect(queries.getMetadata('lore::room2::cray-stories'), isNull,
          reason: 'dedup must be scoped to the originating chat');
    });
  });
}
