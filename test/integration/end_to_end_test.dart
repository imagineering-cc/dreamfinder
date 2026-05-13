import 'package:dreamfinder/src/agent/agent_loop.dart';
import 'package:dreamfinder/src/agent/conversation_history.dart';
import 'package:dreamfinder/src/agent/tool_registry.dart';
import 'package:dreamfinder/src/mcp/mcp_manager.dart';
import 'package:test/test.dart';

void main() {
  test('Matrix message → agent loop → tool call → response', () async {
    final mcp = McpManager();
    mcp.addServerForTesting(
      'kan',
      McpToolInfo(
        name: 'kan_list_boards',
        description: 'List boards',
        handler: (a) async =>
            '{"boards": [{"name": "Sprint Backlog"}, {"name": "Design"}]}',
      ),
    );

    final reg = ToolRegistry()..setMcpManager(mcp);
    var callCount = 0;
    final loop = AgentLoop(
      createMessage: (m, t, s) async {
        callCount++;
        if (callCount == 1) {
          return const AgentResponse(
            textBlocks: [],
            toolUseBlocks: [
              ToolUseContent(
                id: 'c1',
                name: 'kan_list_boards',
                input: <String, dynamic>{},
              ),
            ],
            stopReason: StopReason.toolUse,
          );
        }
        return const AgentResponse(
          textBlocks: [
            TextContent(text: 'We have 2 boards: Sprint Backlog and Design'),
          ],
          toolUseBlocks: [],
          stopReason: StopReason.endTurn,
        );
      },
      toolRegistry: reg,
      history: ConversationHistory(),
    );

    // Simulate a Matrix room message arriving.
    final response = await loop.processMessage(
      const AgentInput(
        text: 'What boards?',
        chatId: '!room123:matrix.test',
        senderId: '@user:matrix.test',
        isAdmin: false,
      ),
      systemPrompt: 'You are River.',
    );

    expect(response, contains('Sprint Backlog'));
    expect(response, contains('Design'));
  });
}
