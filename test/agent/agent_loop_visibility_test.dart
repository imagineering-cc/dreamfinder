import 'package:dreamfinder/src/agent/agent_loop.dart';
import 'package:dreamfinder/src/agent/conversation_history.dart';
import 'package:dreamfinder/src/agent/tool_registry.dart';
import 'package:dreamfinder/src/memory/memory_record.dart';
import 'package:test/test.dart';

import '../helpers/fake_pipeline.dart';

AgentLoop _buildLoop({
  required FakePipeline pipeline,
  required ConversationHistory history,
  required ToolRegistry toolRegistry,
}) {
  return AgentLoop(
    createMessage: (m, t, s) async => const AgentResponse(
      textBlocks: [TextContent(text: 'Got it.')],
      toolUseBlocks: [],
      stopReason: StopReason.endTurn,
    ),
    toolRegistry: toolRegistry,
    history: history,
    embeddingPipeline: pipeline,
  );
}

void main() {
  late FakePipeline pipeline;
  late ConversationHistory history;
  late ToolRegistry toolRegistry;

  setUp(() {
    pipeline = FakePipeline();
    history = ConversationHistory();
    toolRegistry = ToolRegistry();
  });

  group('AgentLoop visibility routing', () {
    test('group chat queues with sameChat visibility', () async {
      final loop = _buildLoop(
        pipeline: pipeline,
        history: history,
        toolRegistry: toolRegistry,
      );
      await loop.processMessage(
        const AgentInput(
          text: 'Plan the next sprint',
          chatId: 'group-1',
          senderUuid: 'u1',
          senderName: 'Alice',
          isAdmin: false,
          isGroup: true,
        ),
        systemPrompt: 'You are Dreamfinder.',
      );

      expect(pipeline.calls, hasLength(1));
      expect(pipeline.calls.first.visibility, MemoryVisibility.sameChat);
    });

    test('1:1 admin chat queues with crossChat visibility', () async {
      final loop = _buildLoop(
        pipeline: pipeline,
        history: history,
        toolRegistry: toolRegistry,
      );
      await loop.processMessage(
        const AgentInput(
          text: 'Update the bot name to Spark',
          chatId: 'dm-admin',
          senderUuid: 'admin-uuid',
          senderName: 'Nick',
          isAdmin: true,
          isGroup: false,
        ),
        systemPrompt: 'You are Dreamfinder.',
      );

      expect(pipeline.calls, hasLength(1));
      expect(pipeline.calls.first.visibility, MemoryVisibility.crossChat);
    });

    test('1:1 non-admin chat queues with private visibility', () async {
      final loop = _buildLoop(
        pipeline: pipeline,
        history: history,
        toolRegistry: toolRegistry,
      );
      await loop.processMessage(
        const AgentInput(
          text: 'What are my tasks?',
          chatId: 'dm-user',
          senderUuid: 'user-uuid',
          senderName: 'Bob',
          isAdmin: false,
          isGroup: false,
        ),
        systemPrompt: 'You are Dreamfinder.',
      );

      expect(pipeline.calls, hasLength(1));
      expect(pipeline.calls.first.visibility, MemoryVisibility.private_);
    });

    test('system-initiated messages do not queue embeddings', () async {
      final loop = _buildLoop(
        pipeline: pipeline,
        history: history,
        toolRegistry: toolRegistry,
      );
      await loop.processMessage(
        const AgentInput(
          text: 'Send the standup prompt',
          chatId: 'group-1',
          senderUuid: 'system',
          isAdmin: true,
          isSystemInitiated: true,
          isGroup: true,
        ),
        systemPrompt: 'You are Dreamfinder.',
      );

      expect(pipeline.calls, isEmpty);
    });
  });
}
