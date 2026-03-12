import 'dart:convert';

import 'package:dreamfinder/src/agent/tool_registry.dart';
import 'package:dreamfinder/src/memory/memory_record.dart';
import 'package:dreamfinder/src/tools/memory_tools.dart';
import 'package:test/test.dart';

import '../helpers/fake_pipeline.dart';

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
    registerMemoryTools(registry, pipeline);
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
      registerMemoryTools(noMemRegistry, null);

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
}
