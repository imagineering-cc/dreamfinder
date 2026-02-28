import 'dart:developer' as developer;
import 'dart:io';

import 'package:anthropic_sdk_dart/anthropic_sdk_dart.dart' as anthropic;

import 'package:imagineering_pm_bot/src/agent/agent_loop.dart';
import 'package:imagineering_pm_bot/src/agent/conversation_history.dart';
import 'package:imagineering_pm_bot/src/agent/system_prompt.dart';
import 'package:imagineering_pm_bot/src/agent/tool_registry.dart';
import 'package:imagineering_pm_bot/src/config/env.dart';
import 'package:imagineering_pm_bot/src/mcp/mcp_manager.dart';
import 'package:imagineering_pm_bot/src/signal/signal_client.dart';

const _pollIntervalSeconds = 5;

Future<void> main() async {
  developer.log('Starting Figment...', name: 'main');

  final env = Env.load();
  developer.log(
    'Config loaded: bot=${env.botName}, signal=${env.signalApiUrl}',
    name: 'main',
  );

  final signalClient = SignalClient(
    baseUrl: env.signalApiUrl,
    phoneNumber: env.signalPhoneNumber,
  );

  try {
    final about = await signalClient.about();
    developer.log(
      'Signal API connected: versions=${about.versions}',
      name: 'main',
    );
  } on Exception catch (e) {
    developer.log('Failed to connect to Signal API: $e',
        name: 'main', level: 1000);
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
  developer.log(
    'MCP servers: ${serverNames.isEmpty ? "(none)" : serverNames.join(", ")}',
    name: 'main',
  );

  final toolRegistry = ToolRegistry();
  toolRegistry.setMcpManager(mcpManager);

  final history = ConversationHistory();
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
    developer.log('Shutting down...', name: 'main');
    mcpManager.shutdown();
    anthropicClient.endSession();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen((_) => shutdown());
  ProcessSignal.sigterm.watch().listen((_) => shutdown());

  developer.log(
    'Figment is running! Polling every ${_pollIntervalSeconds}s...',
    name: 'main',
  );

  while (true) {
    try {
      final envelopes = await signalClient.receiveMessages();
      for (final envelope in envelopes) {
        if (!envelope.hasTextMessage) continue;
        final text = envelope.dataMessage!.message!;
        developer.log('Message from ${envelope.source}: $text', name: 'main');

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
            await signalClient.sendMessage(
              recipient: envelope.chatId,
              message: response,
            );
          }
        } on Exception catch (e) {
          developer.log('Error processing message: $e',
              name: 'main', level: 900);
          try {
            await signalClient.sendMessage(
              recipient: envelope.chatId,
              message: 'Something went wrong. Please try again.',
            );
          } on Exception catch (sendErr) {
            developer.log(
              'Failed to send error message: $sendErr',
              name: 'main',
              level: 900,
            );
          }
        }
      }
    } on Exception catch (e) {
      developer.log('Polling error: $e', name: 'main', level: 900);
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
