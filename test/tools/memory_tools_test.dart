import 'dart:convert';

import 'package:dreamfinder/src/agent/tool_registry.dart';
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
      senderUuid: 'user-1',
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
      expect(pipeline.calls.first.senderUuid, 'user-1');
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
        senderUuid: 'user-1',
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
        senderUuid: 'user-1',
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
        senderUuid: 'user-1',
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
        senderUuid: 'user-1',
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
}
