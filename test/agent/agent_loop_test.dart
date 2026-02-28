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
            textBlocks: [TextContent(text: 'Hello! I am Figment.')],
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
        systemPrompt: 'You are Figment.',
      );
      expect(result, equals('Hello! I am Figment.'));
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
            text: 'What time?', chatId: 'c1', senderUuid: 'u1', isAdmin: false),
        systemPrompt: 'You are Figment.',
      );
      expect(result, contains('2026-02-28T12:00:00Z'));
      expect(callCount, equals(2));
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
        systemPrompt: 'You are Figment.',
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
        systemPrompt: 'You are Figment.',
      );
      expect(result, contains('not working'));
      expect(callCount, equals(2));
    });
  });
}
