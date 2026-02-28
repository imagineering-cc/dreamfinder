import 'dart:developer' as developer;
import 'dart:io';

import 'package:anthropic_sdk_dart/anthropic_sdk_dart.dart' as anthropic;

import 'package:imagineering_pm_bot/src/agent/agent_loop.dart';
import 'package:imagineering_pm_bot/src/agent/conversation_history.dart';
import 'package:imagineering_pm_bot/src/agent/system_prompt.dart';
import 'package:imagineering_pm_bot/src/agent/tool_registry.dart';
import 'package:imagineering_pm_bot/src/config/env.dart';
import 'package:imagineering_pm_bot/src/db/database.dart';
import 'package:imagineering_pm_bot/src/db/message_repository.dart';
import 'package:imagineering_pm_bot/src/mcp/mcp_manager.dart';
import 'package:imagineering_pm_bot/src/signal/signal_client.dart';

const _pollIntervalSeconds = 5;

/// Logs to both stderr (visible in terminal) and Dart DevTools.
void _log(String message, {String name = 'main', bool isError = false}) {
  final timestamp = DateTime.now().toIso8601String().substring(11, 23);
  stderr.writeln('[$timestamp] [$name] $message');
  developer.log(message, name: name, level: isError ? 900 : 0);
}

Future<void> main() async {
  _log('Starting Figment...');

  final env = Env.load();
  _log('Config loaded: bot=${env.botName}, signal=${env.signalApiUrl}');

  // Ensure the database directory exists and open the database.
  final dbPath = env.databasePath;
  final dbDir = File(dbPath).parent;
  if (!dbDir.existsSync()) {
    dbDir.createSync(recursive: true);
  }
  final database = BotDatabase.open(dbPath);
  final messageRepo = MessageRepository(database);
  _log('Database opened: $dbPath');

  final signalClient = SignalClient(
    baseUrl: env.signalApiUrl,
    phoneNumber: env.signalPhoneNumber,
  );

  try {
    final about = await signalClient.about();
    _log('Signal API connected: versions=${about.versions}');
  } on Exception catch (e) {
    _log('Failed to connect to Signal API: $e', isError: true);
    exit(1);
  }

  final mcpManager = McpManager();

  if (env.kanEnabled) {
    await mcpManager.startServer(const McpServerConfig(
      name: 'kan',
      command: 'node',
      args: <String>['mcp-servers/packages/kan/index.js'],
    ));
  }
  if (env.outlineEnabled) {
    await mcpManager.startServer(const McpServerConfig(
      name: 'outline',
      command: 'node',
      args: <String>['mcp-servers/packages/outline/index.js'],
    ));
  }
  if (env.radicaleEnabled) {
    await mcpManager.startServer(const McpServerConfig(
      name: 'radicale',
      command: 'node',
      args: <String>['mcp-servers/packages/radicale/index.js'],
    ));
  }

  final serverNames = mcpManager.getServerNames();
  _log('MCP servers: ${serverNames.isEmpty ? "(none)" : serverNames.join(", ")}');

  final toolRegistry = ToolRegistry();
  toolRegistry.setMcpManager(mcpManager);

  final history = ConversationHistory(repository: messageRepo);
  final anthropicClient = anthropic.AnthropicClient(
    apiKey: env.anthropicApiKey,
  );

  final agentLoop = AgentLoop(
    createMessage: (messages, tools, systemPrompt) async {
      return _callClaude(anthropicClient, messages, tools, systemPrompt);
    },
    toolRegistry: toolRegistry,
    history: history,
    onTyping: (chatId) => signalClient.sendTypingIndicator(recipient: chatId),
  );

  void shutdown() {
    _log('Shutting down...');
    database.close();
    mcpManager.shutdown();
    anthropicClient.endSession();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen((_) => shutdown());
  ProcessSignal.sigterm.watch().listen((_) => shutdown());

  _log('Figment is running! Polling every ${_pollIntervalSeconds}s...');

  while (true) {
    try {
      final envelopes = await signalClient.receiveMessages();
      for (final envelope in envelopes) {
        if (!envelope.hasTextMessage) continue;
        final text = envelope.dataMessage!.message!;
        _log('Message from ${envelope.source}: $text');

        try {
          final input = AgentInput(
            text: text,
            chatId: envelope.chatId,
            senderUuid: envelope.sourceUuid,
            isAdmin: false,
          );
          final response = await agentLoop.processMessage(
            input,
            systemPrompt: buildSystemPrompt(input, botName: env.botName),
          );
          if (response.isNotEmpty) {
            _log('Responding to ${envelope.chatId}: '
                '${response.length > 80 ? '${response.substring(0, 80)}...' : response}');
            await signalClient.sendMessage(
              recipient: envelope.chatId,
              message: response,
            );
            _log('Response sent.');
          }
        } on Exception catch (e) {
          _log('Error processing message: $e', isError: true);
          try {
            await signalClient.sendMessage(
              recipient: envelope.chatId,
              message: 'Something went wrong. Please try again.',
            );
          } on Exception catch (sendErr) {
            _log('Failed to send error message: $sendErr', isError: true);
          }
        }
      }
    } on Exception catch (e) {
      _log('Polling error: $e', isError: true);
    }

    history.evictStale();
    await Future<void>.delayed(const Duration(seconds: _pollIntervalSeconds));
  }
}

/// Bridges agent loop abstract types and `anthropic_sdk_dart`.
Future<AgentResponse> _callClaude(
  anthropic.AnthropicClient client,
  List<AgentMessage> messages,
  List<ToolDefinition> tools,
  String systemPrompt,
) async {
  final sdkMessages = <anthropic.Message>[];
  for (final msg in messages) {
    if (msg.role == 'user') {
      sdkMessages.add(anthropic.Message(
        role: anthropic.MessageRole.user,
        content: anthropic.MessageContent.text(msg.content as String),
      ));
    } else if (msg.role == 'assistant') {
      final content = msg.content;
      sdkMessages.add(anthropic.Message(
        role: anthropic.MessageRole.assistant,
        content: anthropic.MessageContent.text(
          content is String ? content : content.toString(),
        ),
      ));
    } else if (msg.role == 'tool_result') {
      final results = msg.content as List<Map<String, dynamic>>;
      final blocks = <anthropic.Block>[
        for (final r in results)
          anthropic.Block.toolResult(
            toolUseId: r['toolUseId'] as String,
            content: anthropic.ToolResultBlockContent.text(
              r['content'] as String,
            ),
          ),
      ];
      sdkMessages.add(anthropic.Message(
        role: anthropic.MessageRole.user,
        content: anthropic.MessageContent.blocks(blocks),
      ));
    }
  }

  final sdkTools = <anthropic.Tool>[
    for (final tool in tools)
      anthropic.Tool.custom(
        name: tool.name,
        description: tool.description,
        inputSchema: tool.inputSchema,
      ),
  ];

  final response = await client.createMessage(
    request: anthropic.CreateMessageRequest(
      model: const anthropic.Model.modelId('claude-sonnet-4-6'),
      maxTokens: 2048,
      system: anthropic.CreateMessageRequestSystem.text(systemPrompt),
      messages: sdkMessages,
      tools: sdkTools,
    ),
  );

  final textBlocks = <TextContent>[];
  final toolUseBlocks = <ToolUseContent>[];

  for (final block in response.content.blocks) {
    if (block is anthropic.TextBlock) {
      textBlocks.add(TextContent(text: block.text));
    } else if (block is anthropic.ToolUseBlock) {
      toolUseBlocks.add(ToolUseContent(
        id: block.id,
        name: block.name,
        input: block.input,
      ));
    }
  }

  return AgentResponse(
    textBlocks: textBlocks,
    toolUseBlocks: toolUseBlocks,
    stopReason: switch (response.stopReason) {
      anthropic.StopReason.toolUse => StopReason.toolUse,
      anthropic.StopReason.maxTokens => StopReason.maxTokens,
      _ => StopReason.endTurn,
    },
  );
}
