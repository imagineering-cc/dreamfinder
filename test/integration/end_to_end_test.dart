import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:dreamfinder/src/agent/agent_loop.dart';
import 'package:dreamfinder/src/agent/conversation_history.dart';
import 'package:dreamfinder/src/agent/tool_registry.dart';
import 'package:dreamfinder/src/mcp/mcp_manager.dart';
import 'package:dreamfinder/src/signal/signal_client.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

class MockHttpClient extends Mock implements http.Client {}

void main() {
  setUpAll(() {
    registerFallbackValue(Uri.parse('http://x.com'));
  });

  test('Signal message -> agent loop -> tool call -> response', () async {
    final mockHttp = MockHttpClient();
    final signal = SignalClient(
        baseUrl: 'http://localhost:8080',
        phoneNumber: '+1234567890',
        client: mockHttp);

    when(() => mockHttp
            .get(Uri.parse('http://localhost:8080/v1/receive/+1234567890?timeout=10')))
        .thenAnswer((_) async => http.Response(
            jsonEncode([
              {
                'envelope': {
                  'source': '+0987654321',
                  'sourceUuid': 'u-abc',
                  'timestamp': 1709123456789,
                  'dataMessage': {
                    'message': 'What boards?',
                    'timestamp': 1709123456789
                  },
                },
              }
            ]),
            200));

    when(() => mockHttp.post(Uri.parse('http://localhost:8080/v2/send'),
            headers: any(named: 'headers'), body: any(named: 'body')))
        .thenAnswer((_) async =>
            http.Response(jsonEncode({'timestamp': '1709123456790'}), 201));

    when(() => mockHttp.put(any(),
            headers: any(named: 'headers'), body: any(named: 'body')))
        .thenAnswer((_) async => http.Response('', 204));

    final mcp = McpManager();
    mcp.addServerForTesting(
        'kan',
        McpToolInfo(
            name: 'kan_list_boards',
            description: 'List boards',
            handler: (a) async =>
                '{"boards": [{"name": "Sprint Backlog"}, {"name": "Design"}]}'));

    final reg = ToolRegistry()..setMcpManager(mcp);
    var callCount = 0;
    final loop = AgentLoop(
      createMessage: (m, t, s) async {
        callCount++;
        if (callCount == 1) {
          return const AgentResponse(textBlocks: [], toolUseBlocks: [
            ToolUseContent(
                id: 'c1', name: 'kan_list_boards', input: <String, dynamic>{})
          ], stopReason: StopReason.toolUse);
        }
        return const AgentResponse(textBlocks: [
          TextContent(text: 'We have 2 boards: Sprint Backlog and Design')
        ], toolUseBlocks: [], stopReason: StopReason.endTurn);
      },
      toolRegistry: reg,
      history: ConversationHistory(),
    );

    final envelopes = await signal.receiveMessages();
    expect(envelopes, hasLength(1));
    final env = envelopes.first;
    final response = await loop.processMessage(
      AgentInput(
          text: env.dataMessage!.message!,
          chatId: env.source,
          senderUuid: env.sourceUuid,
          isAdmin: false),
      systemPrompt: 'You are Dreamfinder.',
    );
    expect(response, contains('Sprint Backlog'));
    expect(response, contains('Design'));

    final send =
        await signal.sendMessage(recipient: env.source, message: response);
    expect(send.timestamp, isNotNull);
    verify(() => mockHttp.post(Uri.parse('http://localhost:8080/v2/send'),
        headers: any(named: 'headers'), body: any(named: 'body'))).called(1);
  });
}
