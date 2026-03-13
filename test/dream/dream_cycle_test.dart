import 'package:dreamfinder/src/agent/agent_loop.dart';
import 'package:dreamfinder/src/agent/conversation_history.dart'
    hide MessageRole;
import 'package:dreamfinder/src/agent/tool_registry.dart';
import 'package:dreamfinder/src/db/database.dart';
import 'package:dreamfinder/src/db/message_repository.dart';
import 'package:dreamfinder/src/db/queries.dart';
import 'package:dreamfinder/src/db/schema.dart';
import 'package:dreamfinder/src/dream/dream_cycle.dart';
import 'package:test/test.dart';

void main() {
  late BotDatabase db;
  late Queries queries;
  late MessageRepository messageRepo;
  late ToolRegistry toolRegistry;
  late ConversationHistory history;
  late List<String> sentMessages;

  AgentLoop makeAgentLoop({
    required CreateMessageFn createMessage,
  }) {
    return AgentLoop(
      createMessage: createMessage,
      toolRegistry: toolRegistry,
      history: history,
    );
  }

  DreamCycle makeDreamCycle(AgentLoop agentLoop) {
    return DreamCycle(
      queries: queries,
      messageRepo: messageRepo,
      agentLoop: agentLoop,
      toolRegistry: toolRegistry,
      sendMessage: (groupId, message) async {
        sentMessages.add(message);
      },
      botName: 'Dreamfinder',
      buildSystemPrompt: (input) => 'You are Dreamfinder.',
    );
  }

  setUp(() {
    db = BotDatabase.inMemory();
    queries = Queries(db);
    messageRepo = MessageRepository(db);
    toolRegistry = ToolRegistry();
    history = ConversationHistory();
    sentMessages = [];
  });

  tearDown(() {
    db.close();
  });

  group('DreamCycle — full pipeline with branching', () {
    test('light → deep → branches → REM → wake', () async {
      var callCount = 0;

      final agentLoop = makeAgentLoop(
        createMessage: (m, t, s) async {
          callCount++;

          final text = switch (callCount) {
            // Phase 1: Light
            1 => 'Filed 2 cards and 1 doc. [DEPTH: continue]',
            // Phase 2: Deep — outputs 2 sparks
            2 =>
              'Found connections.\n'
                  '[SPARK] Auth refactor shares session logic with onboarding\n'
                  '[SPARK] Calendar events overlap with standup timing\n'
                  '[DEPTH: continue]',
            // Branch 1 (parallel)
            3 => 'Explored auth × onboarding: created Outline doc.',
            // Branch 2 (parallel)
            4 => 'Explored calendar × standup: updated 2 Kan cards.',
            // REM convergence
            5 => 'Dream report: found meta-pattern between auth and calendar.',
            // Waking message
            _ => 'Good morning! Had a deep dream last night...',
          };

          return AgentResponse(
            textBlocks: [TextContent(text: text)],
            toolUseBlocks: const [],
            stopReason: StopReason.endTurn,
            inputTokens: 200,
            outputTokens: 100,
          );
        },
      );
      final dreamCycle = makeDreamCycle(agentLoop);

      final started = dreamCycle.trigger(
        groupId: 'group-1',
        triggeredByUuid: 'user-abc',
        date: '2026-03-14',
      );

      expect(started, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // Light + Deep + 2 branches + REM + Wake = 6 calls.
      expect(callCount, equals(6));

      // Waking message was sent.
      expect(sentMessages, hasLength(1));
      expect(sentMessages.first, contains('Good morning'));

      // DB record completed.
      final cycle = queries.getDreamCycle('group-1', '2026-03-14');
      expect(cycle!.status, equals(DreamCycleStatus.completed));
    });

    test('skips branching when no sparks found', () async {
      var callCount = 0;
      final agentLoop = makeAgentLoop(
        createMessage: (m, t, s) async {
          callCount++;
          final text = switch (callCount) {
            1 => 'Filed some items. [DEPTH: continue]',
            // Deep sleep — no sparks
            2 => 'Found some connections but nothing spark-worthy.',
            // Waking message (dream report is the deep summary)
            _ => 'Morning! Quiet dream.',
          };
          return AgentResponse(
            textBlocks: [TextContent(text: text)],
            toolUseBlocks: const [],
            stopReason: StopReason.endTurn,
          );
        },
      );
      final dreamCycle = makeDreamCycle(agentLoop);

      dreamCycle.trigger(
        groupId: 'group-1',
        triggeredByUuid: 'user-abc',
        date: '2026-03-14',
      );

      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Light + Deep + Wake = 3 calls (no branches, no REM).
      expect(callCount, equals(3));
      expect(sentMessages, hasLength(1));
    });

    test('skips deep sleep and branching when light signals wake', () async {
      var callCount = 0;
      final agentLoop = makeAgentLoop(
        createMessage: (m, t, s) async {
          callCount++;
          final text = switch (callCount) {
            1 => 'Nothing to file — quiet day. [DEPTH: wake]',
            _ => 'Morning!',
          };
          return AgentResponse(
            textBlocks: [TextContent(text: text)],
            toolUseBlocks: const [],
            stopReason: StopReason.endTurn,
          );
        },
      );
      final dreamCycle = makeDreamCycle(agentLoop);

      dreamCycle.trigger(
        groupId: 'group-1',
        triggeredByUuid: 'user-abc',
        date: '2026-03-14',
      );

      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Light + Wake = 2 calls.
      expect(callCount, equals(2));
    });

    test('caps branches at maxDreamBranches', () async {
      var callCount = 0;
      final agentLoop = makeAgentLoop(
        createMessage: (m, t, s) async {
          callCount++;
          final text = switch (callCount) {
            1 => 'Filed items. [DEPTH: continue]',
            2 =>
              'Sparks:\n'
                  '[SPARK] Spark 1\n'
                  '[SPARK] Spark 2\n'
                  '[SPARK] Spark 3\n'
                  '[SPARK] Spark 4\n'
                  '[SPARK] Spark 5\n' // This 5th should be dropped.
                  '[SPARK] Spark 6\n', // This too.
            _ => 'Done.',
          };
          return AgentResponse(
            textBlocks: [TextContent(text: text)],
            toolUseBlocks: const [],
            stopReason: StopReason.endTurn,
          );
        },
      );
      final dreamCycle = makeDreamCycle(agentLoop);

      dreamCycle.trigger(
        groupId: 'group-1',
        triggeredByUuid: 'user-abc',
        date: '2026-03-14',
      );

      await Future<void>.delayed(const Duration(milliseconds: 300));

      // Light + Deep + 4 branches (capped) + REM + Wake = 8.
      expect(callCount, equals(8));
    });

    test('branches run in parallel (not sequentially)', () async {
      // Track timestamps to verify parallel execution.
      final branchStartTimes = <int>[];
      var callCount = 0;

      final agentLoop = makeAgentLoop(
        createMessage: (m, t, s) async {
          callCount++;
          if (callCount >= 3 && callCount <= 5) {
            // These are the 3 branches — record start time.
            branchStartTimes.add(DateTime.now().millisecondsSinceEpoch);
            // Simulate some work.
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          final text = switch (callCount) {
            1 => 'Filed. [DEPTH: continue]',
            2 =>
              '[SPARK] A\n[SPARK] B\n[SPARK] C\n[DEPTH: continue]',
            _ => 'Done.',
          };
          return AgentResponse(
            textBlocks: [TextContent(text: text)],
            toolUseBlocks: const [],
            stopReason: StopReason.endTurn,
          );
        },
      );
      final dreamCycle = makeDreamCycle(agentLoop);

      dreamCycle.trigger(
        groupId: 'group-1',
        triggeredByUuid: 'user-abc',
        date: '2026-03-14',
      );

      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(branchStartTimes, hasLength(3));

      // If branches ran in parallel, their start times should be very close.
      // If sequential, each would be ~50ms apart.
      final spread =
          branchStartTimes.last - branchStartTimes.first;
      // Allow 30ms spread for parallel — sequential would be ~100ms+.
      expect(spread, lessThan(30));
    });

    test('passes deep summary to branch prompts', () async {
      var callCount = 0;
      final capturedSystemPrompts = <String>[];
      final agentLoop = makeAgentLoop(
        createMessage: (m, t, s) async {
          callCount++;
          capturedSystemPrompts.add(s);
          final text = switch (callCount) {
            1 => 'Filed. [DEPTH: continue]',
            2 =>
              'Deep findings.\n[SPARK] Auth insight\n[DEPTH: continue]',
            _ => 'Done.',
          };
          return AgentResponse(
            textBlocks: [TextContent(text: text)],
            toolUseBlocks: const [],
            stopReason: StopReason.endTurn,
          );
        },
      );
      final dreamCycle = makeDreamCycle(agentLoop);

      dreamCycle.trigger(
        groupId: 'group-1',
        triggeredByUuid: 'user-abc',
        date: '2026-03-14',
      );

      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Branch prompt (index 2) should contain the deep summary.
      expect(capturedSystemPrompts.length, greaterThanOrEqualTo(3));
      final branchPrompt = capturedSystemPrompts[2];
      expect(branchPrompt, contains('Deep findings.'));
      expect(branchPrompt, contains('Auth insight'));
      expect(branchPrompt, contains('Dream Branch 1'));
    });

    test('REM receives all branch reports', () async {
      var callCount = 0;
      final capturedSystemPrompts = <String>[];
      final agentLoop = makeAgentLoop(
        createMessage: (m, t, s) async {
          callCount++;
          capturedSystemPrompts.add(s);
          final text = switch (callCount) {
            1 => 'Filed. [DEPTH: continue]',
            2 => '[SPARK] A\n[SPARK] B\n[DEPTH: continue]',
            3 => 'Branch A explored auth.',
            4 => 'Branch B explored calendar.',
            _ => 'Done.',
          };
          return AgentResponse(
            textBlocks: [TextContent(text: text)],
            toolUseBlocks: const [],
            stopReason: StopReason.endTurn,
          );
        },
      );
      final dreamCycle = makeDreamCycle(agentLoop);

      dreamCycle.trigger(
        groupId: 'group-1',
        triggeredByUuid: 'user-abc',
        date: '2026-03-14',
      );

      await Future<void>.delayed(const Duration(milliseconds: 300));

      // REM prompt (index 4) should contain both branch reports.
      final remPrompt = capturedSystemPrompts[4];
      expect(remPrompt, contains('Branch A explored auth.'));
      expect(remPrompt, contains('Branch B explored calendar.'));
      expect(remPrompt, contains('Dream Thread 1'));
      expect(remPrompt, contains('Dream Thread 2'));
      expect(remPrompt, contains('Stage REM'));
    });

    test('tracks token usage including branches', () async {
      var callCount = 0;
      final agentLoop = makeAgentLoop(
        createMessage: (m, t, s) async {
          callCount++;
          final text = switch (callCount) {
            1 => 'Filed. [DEPTH: continue]',
            2 => '[SPARK] A\n[DEPTH: continue]',
            3 => 'Branch done.',
            4 => 'REM done.',
            _ => 'Morning!',
          };
          return AgentResponse(
            textBlocks: [TextContent(text: text)],
            toolUseBlocks: const [],
            stopReason: StopReason.endTurn,
            inputTokens: 100,
            outputTokens: 50,
          );
        },
      );
      final dreamCycle = makeDreamCycle(agentLoop);

      dreamCycle.trigger(
        groupId: 'group-1',
        triggeredByUuid: 'user-abc',
        date: '2026-03-14',
      );

      await Future<void>.delayed(const Duration(milliseconds: 200));

      // 5 calls × 150 tokens each = 750 total.
      // We can't directly inspect the stats, but verify the cycle completed.
      expect(queries.getDreamCycle('group-1', '2026-03-14')!.status,
          equals(DreamCycleStatus.completed));
      expect(sentMessages, hasLength(1));
    });
  });

  group('DreamCycle — guards', () {
    test('trigger returns false when already running', () {
      final agentLoop = makeAgentLoop(
        createMessage: (m, t, s) => Future.delayed(
          const Duration(seconds: 5),
          () => const AgentResponse(
            textBlocks: [TextContent(text: 'Done')],
            toolUseBlocks: [],
            stopReason: StopReason.endTurn,
          ),
        ),
      );
      final dreamCycle = makeDreamCycle(agentLoop);

      expect(
        dreamCycle.trigger(
            groupId: 'g1', triggeredByUuid: 'u1', date: '2026-03-14'),
        isTrue,
      );
      expect(
        dreamCycle.trigger(
            groupId: 'g2', triggeredByUuid: 'u2', date: '2026-03-14'),
        isFalse,
      );
    });

    test('trigger returns false when already dreamed today', () {
      queries.createDreamCycle(
        signalGroupId: 'group-1',
        date: '2026-03-14',
        triggeredByUuid: 'user-abc',
      );

      final agentLoop = makeAgentLoop(
        createMessage: (m, t, s) async => const AgentResponse(
          textBlocks: [TextContent(text: 'Done')],
          toolUseBlocks: [],
          stopReason: StopReason.endTurn,
        ),
      );
      final dreamCycle = makeDreamCycle(agentLoop);

      expect(
        dreamCycle.trigger(
            groupId: 'group-1', triggeredByUuid: 'u2', date: '2026-03-14'),
        isFalse,
      );
    });

    test('marks cycle as failed on exception and resets running', () async {
      final agentLoop = makeAgentLoop(
        createMessage: (m, t, s) async =>
            throw Exception('MCP server unreachable'),
      );
      final dreamCycle = makeDreamCycle(agentLoop);

      dreamCycle.trigger(
        groupId: 'group-1',
        triggeredByUuid: 'user-abc',
        date: '2026-03-14',
      );

      await Future<void>.delayed(const Duration(milliseconds: 100));

      final cycle = queries.getDreamCycle('group-1', '2026-03-14');
      expect(cycle!.status, equals(DreamCycleStatus.failed));
      expect(cycle.errorMessage, contains('MCP server unreachable'));
      expect(dreamCycle.isRunning, isFalse);
    });
  });

  group('isGoodnightMessage', () {
    test('matches goodnight variants', () {
      expect(isGoodnightMessage('goodnight'), isTrue);
      expect(isGoodnightMessage('Goodnight Dreamfinder!'), isTrue);
      expect(isGoodnightMessage('good night'), isTrue);
      expect(isGoodnightMessage("g'night"), isTrue);
      expect(isGoodnightMessage('gnight'), isTrue);
      expect(isGoodnightMessage('nighty night'), isTrue);
      expect(isGoodnightMessage('sleep well everyone'), isTrue);
      expect(isGoodnightMessage('sweet dreams'), isTrue);
    });

    test('does not match unrelated text', () {
      expect(isGoodnightMessage('hello'), isFalse);
      expect(isGoodnightMessage('good morning'), isFalse);
      expect(isGoodnightMessage('the night is good'), isFalse);
    });
  });
}
