import 'package:imagineering_pm_bot/src/agent/agent_loop.dart';
import 'package:imagineering_pm_bot/src/agent/conversation_history.dart';
import 'package:imagineering_pm_bot/src/agent/tool_registry.dart';
import 'package:test/test.dart';

void main() {
  late ConversationHistory history;
  late ToolRegistry toolRegistry;

  setUp(() {
    history = ConversationHistory();
    toolRegistry = ToolRegistry();
  });

  group('AgentLoop', () {
    test('returns text for simple message (no tools)', () async {
      var callCount = 0;
      final loop = AgentLoop(
        createMessage: (m, t, s) async {
          callCount++;
          return const AgentResponse(
            textBlocks: [TextContent(text: 'Hello! I am Dreamfinder.')],
            toolUseBlocks: [],
            stopReason: StopReason.endTurn,
          );
        },
        toolRegistry: toolRegistry,
        history: history,
      );
      final result = await loop.processMessage(
        const AgentInput(
            text: 'Hi', chatId: 'c1', senderUuid: 'u1', isAdmin: false),
        systemPrompt: 'You are Dreamfinder.',
      );
      expect(result, equals('Hello! I am Dreamfinder.'));
      expect(callCount, equals(1));
    });

    test('executes tool call and returns final response', () async {
      var callCount = 0;
      toolRegistry.registerCustomTool(CustomToolDef(
        name: 'get_time',
        description: 'Gets time',
        inputSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{}
        },
        handler: (args) async => '2026-02-28T12:00:00Z',
      ));
      final loop = AgentLoop(
        createMessage: (m, t, s) async {
          callCount++;
          if (callCount == 1) {
            return const AgentResponse(
              textBlocks: [],
              toolUseBlocks: [
                ToolUseContent(
                    id: 't1', name: 'get_time', input: <String, dynamic>{})
              ],
              stopReason: StopReason.toolUse,
            );
          }
          return const AgentResponse(
            textBlocks: [TextContent(text: 'The time is 2026-02-28T12:00:00Z')],
            toolUseBlocks: [],
            stopReason: StopReason.endTurn,
          );
        },
        toolRegistry: toolRegistry,
        history: history,
      );
      final result = await loop.processMessage(
        const AgentInput(
            text: 'What time?',
            chatId: 'c1',
            senderUuid: 'u1',
            isAdmin: false),
        systemPrompt: 'You are Dreamfinder.',
      );
      expect(result, contains('2026-02-28T12:00:00Z'));
      expect(callCount, equals(2));

      // Verify full turn was persisted (not just user+assistant text).
      final msgs = history.getHistory('c1');
      expect(msgs.length, greaterThanOrEqualTo(4));

      // Turn structure: user_text, assistant+tool_use, tool_result, assistant_text
      expect(msgs[0].content, equals('What time?'));
      expect(msgs[0].role, equals(MessageRole.user));

      expect(msgs[1].content, isA<Map>());
      expect(msgs[1].role, equals(MessageRole.assistant));

      expect(msgs[2].content, isA<List>());
      expect(msgs[2].role, equals(MessageRole.user)); // tool_result stored as user

      expect(msgs[3].content, contains('2026-02-28T12:00:00Z'));
      expect(msgs[3].role, equals(MessageRole.assistant));
    });

    test('respects max tool rounds limit', () async {
      var callCount = 0;
      toolRegistry.registerCustomTool(CustomToolDef(
        name: 'loop_tool',
        description: 'Loops',
        inputSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{}
        },
        handler: (args) async => 'result',
      ));
      final loop = AgentLoop(
        createMessage: (m, t, s) async {
          callCount++;
          return AgentResponse(
            textBlocks: const [TextContent(text: 'Working...')],
            toolUseBlocks: [
              ToolUseContent(
                  id: 't-$callCount',
                  name: 'loop_tool',
                  input: const <String, dynamic>{})
            ],
            stopReason: StopReason.toolUse,
          );
        },
        toolRegistry: toolRegistry,
        history: history,
        maxToolRounds: 3,
      );
      final result = await loop.processMessage(
        const AgentInput(
            text: 'Do it', chatId: 'c1', senderUuid: 'u1', isAdmin: false),
        systemPrompt: 'You are Dreamfinder.',
      );
      expect(callCount, equals(3));
      expect(result, isNotEmpty);
    });

    test('handles tool execution errors gracefully', () async {
      var callCount = 0;
      toolRegistry.registerCustomTool(CustomToolDef(
        name: 'broken_tool',
        description: 'Breaks',
        inputSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{}
        },
        handler: (args) async => throw Exception('Tool broken'),
      ));
      final loop = AgentLoop(
        createMessage: (m, t, s) async {
          callCount++;
          if (callCount == 1) {
            return const AgentResponse(
              textBlocks: [],
              toolUseBlocks: [
                ToolUseContent(
                    id: 't1', name: 'broken_tool', input: <String, dynamic>{})
              ],
              stopReason: StopReason.toolUse,
            );
          }
          return const AgentResponse(
            textBlocks: [TextContent(text: 'Sorry, that tool is not working.')],
            toolUseBlocks: [],
            stopReason: StopReason.endTurn,
          );
        },
        toolRegistry: toolRegistry,
        history: history,
      );
      final result = await loop.processMessage(
        const AgentInput(
            text: 'Use it', chatId: 'c1', senderUuid: 'u1', isAdmin: false),
        systemPrompt: 'You are Dreamfinder.',
      );
      expect(result, contains('not working'));
      expect(callCount, equals(2));
    });

    test('passes empty tool list when isSystemInitiated is true', () async {
      List<ToolDefinition>? capturedTools;
      toolRegistry.registerCustomTool(CustomToolDef(
        name: 'some_tool',
        description: 'A tool',
        inputSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{}
        },
        handler: (args) async => 'result',
      ));
      final loop = AgentLoop(
        createMessage: (m, t, s) async {
          capturedTools = List.of(t);
          return const AgentResponse(
            textBlocks: [TextContent(text: 'Composed message')],
            toolUseBlocks: [],
            stopReason: StopReason.endTurn,
          );
        },
        toolRegistry: toolRegistry,
        history: history,
      );
      await loop.processMessage(
        const AgentInput(
          text: 'Send standup prompt',
          chatId: 'c1',
          senderUuid: 'system',
          isAdmin: true,
          isSystemInitiated: true,
        ),
        systemPrompt: 'You are Dreamfinder.',
      );
      expect(capturedTools, isEmpty);
    });

    test('passes tools normally when isSystemInitiated is false', () async {
      List<ToolDefinition>? capturedTools;
      toolRegistry.registerCustomTool(CustomToolDef(
        name: 'some_tool',
        description: 'A tool',
        inputSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{}
        },
        handler: (args) async => 'result',
      ));
      final loop = AgentLoop(
        createMessage: (m, t, s) async {
          capturedTools = List.of(t);
          return const AgentResponse(
            textBlocks: [TextContent(text: 'Hello')],
            toolUseBlocks: [],
            stopReason: StopReason.endTurn,
          );
        },
        toolRegistry: toolRegistry,
        history: history,
      );
      await loop.processMessage(
        const AgentInput(
          text: 'Hi',
          chatId: 'c1',
          senderUuid: 'u1',
          isAdmin: false,
        ),
        systemPrompt: 'You are Dreamfinder.',
      );
      expect(capturedTools, isNotEmpty);
      expect(capturedTools!.any((t) => t.name == 'some_tool'), isTrue);
    });

    test('follow-up request sees prior tool context', () async {
      var callCount = 0;
      toolRegistry.registerCustomTool(CustomToolDef(
        name: 'create_card',
        description: 'Creates a card',
        inputSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{}
        },
        handler: (args) async => '{"id": "card-1", "title": "Test"}',
      ));
      toolRegistry.registerCustomTool(CustomToolDef(
        name: 'assign_card',
        description: 'Assigns a card',
        inputSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{}
        },
        handler: (args) async => '{"id": "card-1", "assignee": "Paul"}',
      ));

      List<AgentMessage>? secondCallMessages;

      final loop = AgentLoop(
        createMessage: (m, t, s) async {
          callCount++;
          if (callCount == 1) {
            // First request — tool call to create card.
            return const AgentResponse(
              textBlocks: [],
              toolUseBlocks: [
                ToolUseContent(
                    id: 't1',
                    name: 'create_card',
                    input: <String, dynamic>{'title': 'Test'})
              ],
              stopReason: StopReason.toolUse,
            );
          } else if (callCount == 2) {
            // First request — final response.
            return const AgentResponse(
              textBlocks: [
                TextContent(text: 'Created card "Test" (card-1).')
              ],
              toolUseBlocks: [],
              stopReason: StopReason.endTurn,
            );
          } else if (callCount == 3) {
            // Second request — capture messages to verify context.
            secondCallMessages = List.of(m);
            return const AgentResponse(
              textBlocks: [],
              toolUseBlocks: [
                ToolUseContent(
                    id: 't2',
                    name: 'assign_card',
                    input: <String, dynamic>{
                      'cardId': 'card-1',
                      'assignee': 'Paul'
                    })
              ],
              stopReason: StopReason.toolUse,
            );
          }
          return const AgentResponse(
            textBlocks: [TextContent(text: 'Assigned to Paul.')],
            toolUseBlocks: [],
            stopReason: StopReason.endTurn,
          );
        },
        toolRegistry: toolRegistry,
        history: history,
      );

      // First request — creates a card.
      await loop.processMessage(
        const AgentInput(
            text: 'Create a card called Test',
            chatId: 'c1',
            senderUuid: 'u1',
            isAdmin: false),
        systemPrompt: 'You are Dreamfinder.',
      );

      // Second request — should see tool context from first turn.
      await loop.processMessage(
        const AgentInput(
            text: 'Now assign it to Paul',
            chatId: 'c1',
            senderUuid: 'u1',
            isAdmin: false),
        systemPrompt: 'You are Dreamfinder.',
      );

      // Verify the second call to Claude included the full first turn.
      expect(secondCallMessages, isNotNull);
      // Messages should include: [first turn (4 msgs), second user text]
      expect(secondCallMessages!.length, greaterThanOrEqualTo(5));

      // First message is the original user text.
      expect(secondCallMessages![0].role, equals('user'));
      expect(secondCallMessages![0].content, equals('Create a card called Test'));

      // Second message is assistant+tool_use.
      expect(secondCallMessages![1].role, equals('assistant'));
      expect(secondCallMessages![1].content, isA<Map>());

      // Third message is tool_result.
      expect(secondCallMessages![2].role, equals('tool_result'));
      expect(secondCallMessages![2].content, isA<List>());

      // Fourth message is assistant text.
      expect(secondCallMessages![3].role, equals('assistant'));

      // Fifth message is the new user text.
      expect(secondCallMessages![4].role, equals('user'));
      expect(secondCallMessages![4].content,
          equals('Now assign it to Paul'));
    });
  });
}
