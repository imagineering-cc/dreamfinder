import 'dart:convert';

import 'package:dreamfinder/src/agent/tool_registry.dart';
import 'package:dreamfinder/src/mcp/mcp_manager.dart';
import 'package:dreamfinder/src/memory/memory_record.dart';
import 'package:dreamfinder/src/tools/memory_tools.dart';
import 'package:test/test.dart';

import '../helpers/fake_pipeline.dart';
import '../helpers/fake_retriever.dart';

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
        MemorySearchResult(
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
        MemorySearchResult(
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
    late McpManager mcpManager;

    /// Helper to build a registry with all sources available.
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
      mcpManager = McpManager();
      mcpManager.addServerForTesting(
        'outline',
        McpToolInfo(
          name: 'outline_search',
          description: 'Search Outline docs',
          handler: (args) async => jsonEncode({
                'data': [
                  {
                    'document': {
                      'id': 'doc-1',
                      'title': 'Sprint Retro Notes',
                      'text': 'We decided to adopt weekly retros.',
                    },
                  },
                ],
              }),
        ),
      );
      mcpManager.addServerForTesting(
        'kan',
        McpToolInfo(
          name: 'kan_search',
          description: 'Search Kan cards',
          handler: (args) async => jsonEncode({
                'data': [
                  {
                    'id': 'card-1',
                    'title': 'Fix auth middleware',
                    'description': 'Rewrite for compliance.',
                    'list': {'name': 'In Progress'},
                  },
                ],
              }),
        ),
      );
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
        mcpManager,
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

    test('gracefully degrades when MCP servers unavailable', () async {
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
      // No MCP manager — only memory available.
      registerMemoryTools(reg, FakePipeline(), ret, null);

      final result = await reg.executeTool('deep_search', {
        'query': 'anything',
      });
      final data = jsonDecode(result) as Map<String, dynamic>;

      expect(data['sources_searched'], contains('memory'));
      final unavailable = data['sources_unavailable'] as List<dynamic>;
      expect(unavailable, containsAll(['outline', 'kan']));
    });

    test('gracefully degrades when retriever is null', () async {
      final reg = ToolRegistry();
      final mcp = McpManager();
      mcp.addServerForTesting(
        'outline',
        McpToolInfo(
          name: 'outline_search',
          description: 'Search Outline',
          handler: (args) async => jsonEncode({
                'data': [
                  {
                    'document': {
                      'id': 'doc-1',
                      'title': 'Test',
                      'text': 'Content',
                    },
                  },
                ],
              }),
        ),
      );
      reg.setContext(const ToolContext(
        senderId: 'user-1',
        isAdmin: false,
        chatId: 'chat-1',
        isGroup: false,
      ));
      // No retriever — only Outline available.
      registerMemoryTools(reg, FakePipeline(), null, mcp);

      final result = await reg.executeTool('deep_search', {
        'query': 'anything',
      });
      final data = jsonDecode(result) as Map<String, dynamic>;

      expect(data['sources_searched'], contains('outline'));
      expect(data['sources_unavailable'], contains('memory'));
    });

    test('handles MCP tool failure for one source', () async {
      // Set up with a broken Outline handler from the start.
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
      final mcp = McpManager();
      mcp.addServerForTesting(
        'outline',
        McpToolInfo(
          name: 'outline_search',
          description: 'Broken Outline',
          handler: (args) async => throw Exception('Connection refused'),
        ),
      );
      mcp.addServerForTesting(
        'kan',
        McpToolInfo(
          name: 'kan_search',
          description: 'Search Kan',
          handler: (args) async => jsonEncode({
                'data': [
                  {
                    'id': 'card-1',
                    'title': 'A card',
                    'description': 'Details',
                    'list': {'name': 'Backlog'},
                  },
                ],
              }),
        ),
      );
      reg.setContext(const ToolContext(
        senderId: 'user-1',
        isAdmin: false,
        chatId: 'chat-1',
        isGroup: true,
      ));
      registerMemoryTools(reg, FakePipeline(), ret, mcp);

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

      final result = await deepRegistry.executeTool('deep_search', {
        'query': 'test',
      });
      final data = jsonDecode(result) as Map<String, dynamic>;

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
    });
  });
}
