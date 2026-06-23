import 'dart:convert';

import 'package:dreamfinder/src/agent/tool_registry.dart';
import 'package:dreamfinder/src/memory/memory_record.dart';
import 'package:dreamfinder/src/tools/cli_tools.dart'
    show CliCompleted, CliLaunchFailure;
import 'package:dreamfinder/src/tools/memory_tools.dart';
import 'package:test/test.dart';

import '../helpers/fake_pipeline.dart';
import '../helpers/fake_retriever.dart';

/// One recorded invocation of the fake [CliRunner].
class CliCall {
  CliCall(this.tool, this.args, this.env);
  final String tool;
  final List<String> args;
  final Map<String, String> env;
}

/// A fake [CliRunner] for deep_search tests: returns canned stdout per tool
/// (no `node` subprocess), or a launch failure for tools in [failTools]. When
/// [calls] is supplied, each invocation is recorded so a test can assert the
/// exact argv/env the production code built (locking the real CLI contract).
CliRunner fakeCliRunner({
  String? outline,
  String? kan,
  Set<String> failTools = const {},
  List<CliCall>? calls,
}) {
  return ({
    required String tool,
    required List<String> args,
    required Map<String, String> env,
  }) async {
    calls?.add(CliCall(tool, args, env));
    if (failTools.contains(tool)) {
      return const CliLaunchFailure('simulated CLI failure');
    }
    final out = tool == 'outline' ? (outline ?? '{"data":[]}') : (kan ?? '[]');
    return CliCompleted(exitCode: 0, stdout: out, stderr: '');
  };
}

void main() {
  late ToolRegistry registry;
  late FakePipeline pipeline;

  setUp(() {
    registry = ToolRegistry();
    pipeline = FakePipeline();
    registry.setContext(const ToolContext(
      senderId: 'user-1',
      isAdmin: false,
      chatId: 'chat-1',
      isGroup: false,
    ));
    registerMemoryTools(registry, pipeline, null);
  });

  group('save_memory tool', () {
    test('saves with default visibility (same_chat)', () async {
      final result = await registry.executeTool('save_memory', {
        'content': 'The team prefers morning standups at 9am.',
      });
      final data = jsonDecode(result) as Map<String, dynamic>;

      expect(data['success'], isTrue);
      expect(pipeline.calls, hasLength(1));
      expect(pipeline.calls.first.visibility, MemoryVisibility.sameChat);
      expect(pipeline.calls.first.chatId, 'chat-1');
      expect(pipeline.calls.first.senderId, 'user-1');
    });

    test('saves with explicit cross_chat visibility', () async {
      final result = await registry.executeTool('save_memory', {
        'content': 'My name is Nick and I am the admin.',
        'visibility': 'cross_chat',
      });
      final data = jsonDecode(result) as Map<String, dynamic>;

      expect(data['success'], isTrue);
      expect(pipeline.calls, hasLength(1));
      expect(pipeline.calls.first.visibility, MemoryVisibility.crossChat);
    });

    test('saves with explicit private visibility', () async {
      final result = await registry.executeTool('save_memory', {
        'content': 'Personal preference: dark mode.',
        'visibility': 'private',
      });
      final data = jsonDecode(result) as Map<String, dynamic>;

      expect(data['success'], isTrue);
      expect(pipeline.calls, hasLength(1));
      expect(pipeline.calls.first.visibility, MemoryVisibility.private_);
    });

    test('returns error when pipeline is null', () async {
      final noMemRegistry = ToolRegistry();
      noMemRegistry.setContext(const ToolContext(
        senderId: 'user-1',
        isAdmin: false,
        chatId: 'chat-1',
        isGroup: false,
      ));
      registerMemoryTools(noMemRegistry, null, null);

      final result = await noMemRegistry.executeTool('save_memory', {
        'content': 'Something to remember.',
      });
      final data = jsonDecode(result) as Map<String, dynamic>;

      expect(data['error'], contains('memory'));
    });

    test('returns error when content is empty', () async {
      final result = await registry.executeTool('save_memory', {
        'content': '',
      });
      final data = jsonDecode(result) as Map<String, dynamic>;

      expect(data['error'], contains('empty'));
      expect(pipeline.calls, isEmpty);
    });

    test('returns error when content is whitespace-only', () async {
      final result = await registry.executeTool('save_memory', {
        'content': '   ',
      });
      final data = jsonDecode(result) as Map<String, dynamic>;

      expect(data['error'], contains('empty'));
      expect(pipeline.calls, isEmpty);
    });

    test('content is stored correctly in queued embedding', () async {
      await registry.executeTool('save_memory', {
        'content': 'Sprint ends on Friday 2026-03-20.',
      });

      expect(pipeline.calls, hasLength(1));
      // The save_memory tool stores the content as userText with a marker
      // assistantText so it's distinguishable from conversation turns.
      expect(
        pipeline.calls.first.userText,
        contains('Sprint ends on Friday 2026-03-20.'),
      );
    });
  });

  group('search_memory tool', () {
    late ToolRegistry searchRegistry;
    late FakeRetriever retriever;

    setUp(() {
      searchRegistry = ToolRegistry();
      retriever = FakeRetriever(results: [
        const MemorySearchResult(
          record: MemoryRecord(
            id: 1,
            chatId: 'chat-1',
            sourceType: MemorySourceType.message,
            sourceText: 'Dawn Gate is an emoji gateway',
            visibility: MemoryVisibility.sameChat,
            embedding: [1.0, 0.0, 0.0],
            createdAt: '2026-03-01T12:00:00',
          ),
          score: 0.95,
        ),
        const MemorySearchResult(
          record: MemoryRecord(
            id: 2,
            chatId: 'chat-1',
            sourceType: MemorySourceType.summary,
            sourceText: 'Team discussed calendar setup',
            visibility: MemoryVisibility.crossChat,
            embedding: [0.0, 1.0, 0.0],
            createdAt: '2026-03-02T12:00:00',
          ),
          score: 0.72,
        ),
      ]);
      searchRegistry.setContext(const ToolContext(
        senderId: 'user-1',
        isAdmin: false,
        chatId: 'chat-1',
        isGroup: true,
      ));
      registerMemoryTools(searchRegistry, FakePipeline(), retriever);
    });

    test('returns results from retriever with correct JSON structure',
        () async {
      final result = await searchRegistry.executeTool('search_memory', {
        'query': 'Dawn Gate',
      });
      final data = jsonDecode(result) as Map<String, dynamic>;

      expect(data['count'], equals(2));
      final results = data['results'] as List<dynamic>;
      expect(results, hasLength(2));

      final first = results[0] as Map<String, dynamic>;
      expect(first['source_text'], equals('Dawn Gate is an emoji gateway'));
      expect(first['date'], equals('2026-03-01'));
      expect(first['score'], closeTo(0.95, 0.01));
      expect(first['visibility'], equals('same_chat'));
      expect(first['source_type'], equals('message'));
    });

    test('returns error when retriever is null', () async {
      final noRetrieverRegistry = ToolRegistry();
      noRetrieverRegistry.setContext(const ToolContext(
        senderId: 'user-1',
        isAdmin: false,
        chatId: 'chat-1',
        isGroup: false,
      ));
      registerMemoryTools(noRetrieverRegistry, FakePipeline(), null);

      final result = await noRetrieverRegistry.executeTool('search_memory', {
        'query': 'anything',
      });
      final data = jsonDecode(result) as Map<String, dynamic>;
      expect(data['error'], contains('memory'));
    });

    test('returns error when query is empty', () async {
      final result = await searchRegistry.executeTool('search_memory', {
        'query': '',
      });
      final data = jsonDecode(result) as Map<String, dynamic>;
      expect(data['error'], contains('empty'));
    });

    test('returns error when query is whitespace-only', () async {
      final result = await searchRegistry.executeTool('search_memory', {
        'query': '   ',
      });
      final data = jsonDecode(result) as Map<String, dynamic>;
      expect(data['error'], contains('empty'));
    });

    test('clamps limit to max 10 and defaults to 5', () async {
      // Default limit should be 5.
      await searchRegistry.executeTool('search_memory', {
        'query': 'test',
      });
      expect(retriever.lastTopK, equals(5));

      // Explicit limit of 15 should be clamped to 10.
      await searchRegistry.executeTool('search_memory', {
        'query': 'test',
        'limit': 15,
      });
      expect(retriever.lastTopK, equals(10));
    });

    test('passes chatId from tool context to retriever', () async {
      await searchRegistry.executeTool('search_memory', {
        'query': 'Dawn Gate',
      });

      expect(retriever.lastChatId, equals('chat-1'));
    });

    test('handles retriever returning empty results', () async {
      final emptyRetriever = FakeRetriever(results: []);
      final emptyRegistry = ToolRegistry();
      emptyRegistry.setContext(const ToolContext(
        senderId: 'user-1',
        isAdmin: false,
        chatId: 'chat-1',
        isGroup: false,
      ));
      registerMemoryTools(emptyRegistry, FakePipeline(), emptyRetriever);

      final result = await emptyRegistry.executeTool('search_memory', {
        'query': 'nonexistent topic',
      });
      final data = jsonDecode(result) as Map<String, dynamic>;

      expect(data['count'], equals(0));
      expect(data['results'], isEmpty);
    });
  });

  group('deep_search tool', () {
    late ToolRegistry deepRegistry;
    late FakeRetriever retriever;

    // Shapes verified against the live CLIs: Outline documents.search returns
    // {data:[{context, document:{...}}]} with a populated document.text; the
    // Kan `search` CLI returns a BARE ARRAY of cards (publicId/listName/...).
    const outlineJson =
        '{"data":[{"context":"...retros...","document":{"id":"doc-1",'
        '"title":"Sprint Retro Notes",'
        '"text":"We decided to adopt weekly retros."}}]}';
    const kanJson = '[{"publicId":"card-1","title":"Fix auth middleware",'
        '"description":"Rewrite for compliance.","boardName":"Engineering",'
        '"listName":"In Progress"}]';

    /// Builds a registry with all three sources available: a memory retriever,
    /// plus Outline + Kan creds (incl. a Kan workspace id) wired to a fake CLI
    /// runner returning canned search JSON.
    void setUpAllSources() {
      deepRegistry = ToolRegistry();
      retriever = FakeRetriever(results: [
        const MemorySearchResult(
          record: MemoryRecord(
            id: 1,
            chatId: 'chat-1',
            sourceType: MemorySourceType.message,
            sourceText: 'Dawn Gate is an emoji gateway',
            visibility: MemoryVisibility.sameChat,
            embedding: [1.0, 0.0, 0.0],
            createdAt: '2026-03-01T12:00:00',
          ),
          score: 0.95,
        ),
      ]);
      deepRegistry.setContext(const ToolContext(
        senderId: 'user-1',
        isAdmin: false,
        chatId: 'chat-1',
        isGroup: true,
      ));
      registerMemoryTools(
        deepRegistry,
        FakePipeline(),
        retriever,
        outlineApiKey: 'o',
        outlineBaseUrl: 'https://outline.example/api',
        kanApiKey: 'k',
        kanBaseUrl: 'https://kan.example/api/v1',
        kanWorkspaceId: 'ws-1',
        cliRunner: fakeCliRunner(outline: outlineJson, kan: kanJson),
      );
    }

    test('searches all available sources in parallel', () async {
      setUpAllSources();

      final result = await deepRegistry.executeTool('deep_search', {
        'query': 'retro decisions',
      });
      final data = jsonDecode(result) as Map<String, dynamic>;

      final searched = data['sources_searched'] as List<dynamic>;
      expect(searched, containsAll(['memory', 'outline', 'kan']));
      expect(data['sources_unavailable'], isEmpty);
    });

    test('returns unified results with source attribution', () async {
      setUpAllSources();

      final result = await deepRegistry.executeTool('deep_search', {
        'query': 'retro decisions',
      });
      final data = jsonDecode(result) as Map<String, dynamic>;

      final results = data['results'] as List<dynamic>;
      expect(results, isNotEmpty);

      // Each result should have a 'source' field.
      for (final r in results) {
        final item = r as Map<String, dynamic>;
        expect(item, contains('source'));
        expect(
          item['source'],
          anyOf(equals('memory'), equals('outline'), equals('kan')),
        );
        expect(item, contains('text'));
      }
    });

    test('respects sources parameter', () async {
      setUpAllSources();

      final result = await deepRegistry.executeTool('deep_search', {
        'query': 'Dawn Gate',
        'sources': ['memory'],
      });
      final data = jsonDecode(result) as Map<String, dynamic>;

      final searched = data['sources_searched'] as List<dynamic>;
      expect(searched, equals(['memory']));

      // Only memory results should be present.
      final results = data['results'] as List<dynamic>;
      for (final r in results) {
        expect((r as Map<String, dynamic>)['source'], equals('memory'));
      }
    });

    test('degrades to memory-only when Outline/Kan creds absent', () async {
      final reg = ToolRegistry();
      final ret = FakeRetriever(results: [
        const MemorySearchResult(
          record: MemoryRecord(
            id: 1,
            chatId: 'chat-1',
            sourceType: MemorySourceType.message,
            sourceText: 'Some memory',
            visibility: MemoryVisibility.sameChat,
            embedding: [1.0, 0.0, 0.0],
            createdAt: '2026-03-01T12:00:00',
          ),
          score: 0.8,
        ),
      ]);
      reg.setContext(const ToolContext(
        senderId: 'user-1',
        isAdmin: false,
        chatId: 'chat-1',
        isGroup: false,
      ));
      // No Outline/Kan creds — only memory available.
      registerMemoryTools(reg, FakePipeline(), ret);

      final result = await reg.executeTool('deep_search', {
        'query': 'anything',
      });
      final data = jsonDecode(result) as Map<String, dynamic>;

      expect(data['sources_searched'], contains('memory'));
      final unavailable = data['sources_unavailable'] as List<dynamic>;
      expect(unavailable, containsAll(['outline', 'kan']));
    });

    test('Kan is unavailable without a workspace id (Outline still works)',
        () async {
      final reg = ToolRegistry();
      reg.setContext(const ToolContext(
        senderId: 'user-1',
        isAdmin: false,
        chatId: 'chat-1',
        isGroup: false,
      ));
      // Outline creds present, Kan creds present, but NO kanWorkspaceId.
      registerMemoryTools(
        reg,
        FakePipeline(),
        null,
        outlineApiKey: 'o',
        outlineBaseUrl: 'https://outline.example/api',
        kanApiKey: 'k',
        kanBaseUrl: 'https://kan.example/api/v1',
        cliRunner: fakeCliRunner(outline: outlineJson),
      );

      final result = await reg.executeTool('deep_search', {
        'query': 'anything',
      });
      final data = jsonDecode(result) as Map<String, dynamic>;

      expect(data['sources_searched'], contains('outline'));
      final unavailable = data['sources_unavailable'] as List<dynamic>;
      expect(unavailable, containsAll(['memory', 'kan']));
    });

    test('gracefully degrades when retriever is null', () async {
      final reg = ToolRegistry();
      reg.setContext(const ToolContext(
        senderId: 'user-1',
        isAdmin: false,
        chatId: 'chat-1',
        isGroup: false,
      ));
      // No retriever — only Outline available.
      registerMemoryTools(
        reg,
        FakePipeline(),
        null,
        outlineApiKey: 'o',
        outlineBaseUrl: 'https://outline.example/api',
        cliRunner: fakeCliRunner(outline: outlineJson),
      );

      final result = await reg.executeTool('deep_search', {
        'query': 'anything',
      });
      final data = jsonDecode(result) as Map<String, dynamic>;

      expect(data['sources_searched'], contains('outline'));
      expect(data['sources_unavailable'], contains('memory'));
    });

    test('records a source in sources_failed when its CLI fails', () async {
      final reg = ToolRegistry();
      final ret = FakeRetriever(results: [
        const MemorySearchResult(
          record: MemoryRecord(
            id: 1,
            chatId: 'chat-1',
            sourceType: MemorySourceType.message,
            sourceText: 'Some memory',
            visibility: MemoryVisibility.sameChat,
            embedding: [1.0, 0.0, 0.0],
            createdAt: '2026-03-01T12:00:00',
          ),
          score: 0.8,
        ),
      ]);
      reg.setContext(const ToolContext(
        senderId: 'user-1',
        isAdmin: false,
        chatId: 'chat-1',
        isGroup: true,
      ));
      // Outline CLI fails; Kan succeeds; memory succeeds.
      registerMemoryTools(
        reg,
        FakePipeline(),
        ret,
        outlineApiKey: 'o',
        outlineBaseUrl: 'https://outline.example/api',
        kanApiKey: 'k',
        kanBaseUrl: 'https://kan.example/api/v1',
        kanWorkspaceId: 'ws-1',
        cliRunner: fakeCliRunner(kan: kanJson, failTools: {'outline'}),
      );

      final result = await reg.executeTool('deep_search', {
        'query': 'test',
      });
      final data = jsonDecode(result) as Map<String, dynamic>;

      // Memory and Kan should still succeed.
      final searched = data['sources_searched'] as List<dynamic>;
      expect(searched, containsAll(['memory', 'kan']));

      // Outline should appear in sources_failed.
      final failed = data['sources_failed'] as List<dynamic>;
      expect(failed, isNotEmpty);
      expect(failed.first.toString(), contains('outline'));
    });

    test('returns error when query is empty', () async {
      setUpAllSources();

      final result = await deepRegistry.executeTool('deep_search', {
        'query': '',
      });
      final data = jsonDecode(result) as Map<String, dynamic>;
      expect(data['error'], contains('empty'));
    });

    test('clamps limit and defaults to 3', () async {
      setUpAllSources();

      await deepRegistry.executeTool('deep_search', {
        'query': 'test',
      });

      // Memory retriever should receive limit of 3.
      expect(retriever.lastTopK, equals(3));

      // Explicit limit of 20 should clamp to 5.
      await deepRegistry.executeTool('deep_search', {
        'query': 'test',
        'limit': 20,
      });
      expect(retriever.lastTopK, equals(5));
    });

    test('passes chatId from context to retriever', () async {
      setUpAllSources();

      await deepRegistry.executeTool('deep_search', {
        'query': 'Dawn Gate',
      });

      expect(retriever.lastChatId, equals('chat-1'));
    });

    test('normalizes Outline results into unified format', () async {
      setUpAllSources();

      final result = await deepRegistry.executeTool('deep_search', {
        'query': 'retro',
        'sources': ['outline'],
      });
      final data = jsonDecode(result) as Map<String, dynamic>;
      final results = data['results'] as List<dynamic>;

      expect(results, hasLength(1));
      final outlineResult = results[0] as Map<String, dynamic>;
      expect(outlineResult['source'], equals('outline'));
      expect(outlineResult['title'], equals('Sprint Retro Notes'));
      expect(outlineResult['text'], contains('weekly retros'));
      expect(outlineResult['document_id'], equals('doc-1'));
    });

    test('normalizes Kan results into unified format', () async {
      setUpAllSources();

      final result = await deepRegistry.executeTool('deep_search', {
        'query': 'auth',
        'sources': ['kan'],
      });
      final data = jsonDecode(result) as Map<String, dynamic>;
      final results = data['results'] as List<dynamic>;

      expect(results, hasLength(1));
      final kanResult = results[0] as Map<String, dynamic>;
      expect(kanResult['source'], equals('kan'));
      expect(kanResult['title'], equals('Fix auth middleware'));
      expect(kanResult['text'], contains('compliance'));
      expect(kanResult['card_id'], equals('card-1'));
      expect(kanResult['list'], equals('In Progress'));
    });

    test('builds the expected CLI argv + env for each source', () async {
      final calls = <CliCall>[];
      final reg = ToolRegistry();
      reg.setContext(const ToolContext(
        senderId: 'user-1',
        isAdmin: false,
        chatId: 'chat-1',
        isGroup: true,
      ));
      registerMemoryTools(
        reg,
        FakePipeline(),
        null,
        outlineApiKey: 'o-key',
        outlineBaseUrl: 'https://outline.example/api',
        kanApiKey: 'k-key',
        kanBaseUrl: 'https://kan.example/api/v1',
        kanWorkspaceId: 'ws-1',
        cliRunner:
            fakeCliRunner(outline: outlineJson, kan: kanJson, calls: calls),
      );

      await reg
          .executeTool('deep_search', {'query': 'hackerspace', 'limit': 4});

      final outlineCall = calls.firstWhere((c) => c.tool == 'outline');
      expect(
        outlineCall.args,
        equals(['documents.search', '--query', 'hackerspace', '--limit', '4']),
      );
      // The outline CLI reads OUTLINE_API_URL (not OUTLINE_BASE_URL); creds are
      // present and no unrelated secrets leak into the child env.
      expect(outlineCall.env['OUTLINE_API_KEY'], equals('o-key'));
      expect(outlineCall.env['OUTLINE_API_URL'],
          equals('https://outline.example/api'));
      expect(outlineCall.env.containsKey('PATH'), isTrue);

      final kanCall = calls.firstWhere((c) => c.tool == 'kan');
      expect(
        kanCall.args,
        equals([
          'search',
          '--workspace-id',
          'ws-1',
          '--query',
          'hackerspace',
          '--limit',
          '4',
        ]),
      );
      expect(kanCall.env['KAN_API_KEY'], equals('k-key'));
    });
  });
}
