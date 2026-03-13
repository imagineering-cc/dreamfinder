import 'dart:io';

import 'package:anthropic_sdk_dart/anthropic_sdk_dart.dart' as anthropic;
import 'package:timezone/data/latest.dart' as tzdata;

import 'package:dreamfinder/src/agent/agent_loop.dart';
import 'package:dreamfinder/src/agent/calendar_retriever.dart';
import 'package:dreamfinder/src/agent/conversation_history.dart';
import 'package:dreamfinder/src/agent/system_prompt.dart';
import 'package:dreamfinder/src/agent/tool_registry.dart';
import 'package:dreamfinder/src/bot/deploy_announcer.dart';
import 'package:dreamfinder/src/bot/group_continuation.dart';
import 'package:dreamfinder/src/bot/health_check.dart';
import 'package:dreamfinder/src/bot/rate_limiter.dart';
import 'package:dreamfinder/src/config/env.dart';
import 'package:dreamfinder/src/config/oauth_client.dart';
import 'package:dreamfinder/src/config/version.dart';
import 'package:dreamfinder/src/cron/scheduler.dart';
import 'package:dreamfinder/src/db/database.dart';
import 'package:dreamfinder/src/db/message_repository.dart';
import 'package:dreamfinder/src/db/queries.dart';
import 'package:dreamfinder/src/logging/logger.dart';
import 'package:dreamfinder/src/mcp/mcp_manager.dart';
import 'package:dreamfinder/src/memory/embedding_backfill.dart';
import 'package:dreamfinder/src/memory/embedding_client.dart';
import 'package:dreamfinder/src/memory/embedding_pipeline.dart';
import 'package:dreamfinder/src/memory/memory_consolidator.dart';
import 'package:dreamfinder/src/memory/memory_record.dart';
import 'package:dreamfinder/src/memory/memory_retriever.dart';
import 'package:dreamfinder/src/memory/summarization_client.dart';
import 'package:dreamfinder/src/signal/signal_client.dart';
import 'package:dreamfinder/src/tools/bot_identity_tools.dart';
import 'package:dreamfinder/src/tools/chat_config_tools.dart';
import 'package:dreamfinder/src/tools/memory_tools.dart';
import 'package:dreamfinder/src/tools/standup_tools.dart';

// Short backoff between poll cycles — the actual wait happens server-side
// via long-polling in receiveMessages (10s timeout).
const _pollIntervalSeconds = 1;

Future<void> main() async {
  tzdata.initializeTimeZones();
  final env = Env.load();
  final log = BotLogger(
    name: 'Main',
    level: LogLevel.fromString(env.logLevel),
  );

  log.info('Starting Dreamfinder v$appVersion ($appCommit)');
  log.info('Config loaded', extra: {
    'bot': env.botName,
    'signal': env.signalApiUrl,
  });

  // Start health check server.
  final health = HealthCheck(
    version: appVersion,
    commit: appCommit,
    buildTime: appBuildTime,
  );
  final healthPort = await health.start(port: env.healthPort);
  log.info('Health check listening', extra: {'port': healthPort});

  // Ensure the database directory exists and open the database.
  final dbPath = env.databasePath;
  final dbDir = File(dbPath).parent;
  if (!dbDir.existsSync()) {
    dbDir.createSync(recursive: true);
  }
  final database = BotDatabase.open(dbPath);
  final messageRepo = MessageRepository(database);
  log.info('Database opened', extra: {'path': dbPath});

  final signalClient = SignalClient(
    baseUrl: env.signalApiUrl,
    phoneNumber: env.signalPhoneNumber,
  );

  try {
    final about = await signalClient.about();
    log.info('Signal API connected', extra: {'versions': about.versions});
    await signalClient.loadGroupMappings();
    log.info('Group mappings loaded');
  } on Exception catch (e) {
    log.error('Failed to connect to Signal API: $e');
    exit(1);
  }

  final mcpManager = McpManager();

  if (env.kanEnabled) {
    final kanPath = env.kanMcpPath ?? 'mcp-servers/kan/index.js';
    await mcpManager.startServer(McpServerConfig(
      name: 'kan',
      command: 'node',
      args: <String>[kanPath],
      env: <String, String>{
        'KAN_BASE_URL': env.kanBaseUrl!,
        'KAN_API_KEY': env.kanApiKey!,
      },
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
  log.info('MCP servers: ${serverNames.isEmpty ? "(none)" : serverNames.join(", ")}');

  // Set up calendar event awareness — optional, enabled when CALENDAR_URL is
  // set and Radicale MCP is running.
  CalendarRetriever? calendarRetriever;
  if (env.calendarUrl != null && env.radicaleEnabled) {
    calendarRetriever = CalendarRetriever(
      mcpManager: mcpManager,
      calendarUrl: env.calendarUrl!,
    );
    log.info('Calendar awareness enabled', extra: {'url': env.calendarUrl});
  }

  final queries = Queries(database);

  final toolRegistry = ToolRegistry();
  toolRegistry.setMcpManager(mcpManager);
  registerBotIdentityTools(toolRegistry, queries);
  registerChatConfigTools(toolRegistry, queries);
  registerStandupTools(toolRegistry, queries);
  // Memory tools registered after pipeline creation below.

  final history = ConversationHistory(repository: messageRepo);

  // Set up RAG memory system — optional, enabled when VOYAGE_API_KEY is set.
  EmbeddingPipeline? embeddingPipeline;
  MemoryRetriever? memoryRetriever;
  MemoryConsolidator? memoryConsolidator;
  EmbeddingBackfill? embeddingBackfill;
  EmbeddingClient? voyageClient;

  if (env.voyageEnabled) {
    voyageClient = VoyageEmbeddingClient(apiKey: env.voyageApiKey!);
    embeddingPipeline = EmbeddingPipeline(
      client: voyageClient,
      queries: queries,
      getBotName: () => queries.getBotIdentity()?.name ?? env.botName,
    );
    memoryRetriever = MemoryRetriever(
      client: voyageClient,
      loadMemories: (chatId) => queries.getVisibleMemories(chatId),
    );
    embeddingBackfill = EmbeddingBackfill(
      queries: queries,
      client: voyageClient,
    );
    // Consolidator will be fully wired after the Anthropic client is created
    // (needs the summarization callback). Placeholder set below.
    log.info('RAG memory system enabled (Voyage AI)');
  } else {
    log.info('RAG memory system disabled (no VOYAGE_API_KEY)');
  }

  registerMemoryTools(toolRegistry, embeddingPipeline, memoryRetriever);

  // Set up Anthropic client — OAuth (Claude Max) or API key.
  OAuthTokenManager? oauthManager;
  anthropic.AnthropicClient anthropicClient;

  if (env.useOAuth) {
    oauthManager = OAuthTokenManager(
      queries: queries,
      log: BotLogger(name: 'OAuth', level: LogLevel.fromString(env.logLevel)),
      initialRefreshToken: env.claudeRefreshToken,
    );
    // Create initial client with empty key — headers are set per-request.
    anthropicClient = anthropic.AnthropicClient(apiKey: '');
    log.info('Auth mode: OAuth (Claude Max)');
  } else {
    anthropicClient = anthropic.AnthropicClient(apiKey: env.anthropicApiKey!);
    log.info('Auth mode: API key');
  }

  // Track the last access token so we only recreate the client on refresh.
  String? _lastOAuthToken;

  final agentLoop = AgentLoop(
    createMessage: (messages, tools, systemPrompt) async {
      if (oauthManager != null) {
        final token = await oauthManager.getAccessToken();
        if (token != _lastOAuthToken) {
          _lastOAuthToken = token;
          anthropicClient = anthropic.AnthropicClient(
            apiKey: '',
            headers: {
              'Authorization': 'Bearer $token',
              'anthropic-beta': 'oauth-2025-04-20',
            },
          );
        }
      }
      return _callClaude(anthropicClient, messages, tools, systemPrompt);
    },
    toolRegistry: toolRegistry,
    history: history,
    onTyping: (chatId) => signalClient.sendTypingIndicator(recipient: chatId),
    embeddingPipeline: embeddingPipeline,
  );

  // Wire up memory consolidator now that the Anthropic client exists.
  if (env.voyageEnabled && voyageClient != null) {
    final summarizer = SummarizationClient(
      createSummarization: (prompt) async {
        // Refresh OAuth token if needed (same pattern as agent loop).
        if (oauthManager != null) {
          final token = await oauthManager.getAccessToken();
          if (token != _lastOAuthToken) {
            _lastOAuthToken = token;
            anthropicClient = anthropic.AnthropicClient(
              apiKey: '',
              headers: {
                'Authorization': 'Bearer $token',
                'anthropic-beta': 'oauth-2025-04-20',
              },
            );
          }
        }
        final response = await anthropicClient.createMessage(
          request: anthropic.CreateMessageRequest(
            model: const anthropic.Model.modelId('claude-haiku-4-5-20251001'),
            maxTokens: 512,
            messages: [
              anthropic.Message(
                role: anthropic.MessageRole.user,
                content: anthropic.MessageContent.text(prompt),
              ),
            ],
          ),
        );
        // Extract text from response blocks.
        final buffer = StringBuffer();
        for (final block in response.content.blocks) {
          if (block is anthropic.TextBlock) {
            buffer.write(block.text);
          }
        }
        return buffer.toString();
      },
    );
    memoryConsolidator = MemoryConsolidator(
      queries: queries,
      summarizer: summarizer,
      embeddingClient: voyageClient,
    );
    log.info('Memory consolidator enabled');
  }

  final rateLimiter = RateLimiter();

  final scheduler = Scheduler(
    queries: queries,
    sendMessage: (groupId, message) =>
        signalClient.sendMessage(recipient: groupId, message: message),
    backfill: embeddingBackfill,
    consolidator: memoryConsolidator,
    composeViaAgent: (groupId, taskDescription) async {
      final input = AgentInput(
        text: taskDescription,
        chatId: groupId,
        senderUuid: 'system',
        isAdmin: true,
        isSystemInitiated: true,
      );
      return agentLoop.processMessage(
        input,
        systemPrompt: buildSystemPrompt(
          input,
          botName: env.botName,
          identity: queries.getBotIdentity(),
        ),
      );
    },
  );
  scheduler.start();
  log.info('Scheduler started');

  // Announce deploy if version changed — Dreamfinder reads its own changelog
  // and announces its reimagining in its own voice.
  final announceGroupId = env.deployAnnounceGroupId;
  if (announceGroupId != null && appChangelog.trim().isNotEmpty) {
    final announcer = DeployAnnouncer(
      queries: queries,
      composeViaAgent: (groupId, taskDescription) async {
        final input = AgentInput(
          text: taskDescription,
          chatId: groupId,
          senderUuid: 'system',
          isAdmin: true,
          isSystemInitiated: true,
        );
        return agentLoop.processMessage(
          input,
          systemPrompt: buildSystemPrompt(
            input,
            botName: env.botName,
            identity: queries.getBotIdentity(),
          ),
        );
      },
      sendMessage: (groupId, message) =>
          signalClient.sendMessage(recipient: groupId, message: message),
      currentVersion: '$appVersion+$appCommit',
      changelog: appChangelog,
      diffStat: appDiffStat,
      groupId: announceGroupId,
      log: log,
    );
    final announced = await announcer.announceIfNewVersion();
    if (announced) {
      log.info('Deploy announcement sent', extra: {'group': announceGroupId});
    }
  }

  void shutdown() {
    log.info('Shutting down...');
    scheduler.stop();
    health.stop();
    database.close();
    mcpManager.shutdown();
    anthropicClient.endSession();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen((_) => shutdown());
  ProcessSignal.sigterm.watch().listen((_) => shutdown());

  // Cache the bot name for mention detection — avoids a DB hit per message.
  // Refreshed when `set_bot_identity` fires via the onIdentityChanged callback.
  var cachedBotName =
      (queries.getBotIdentity()?.name ?? env.botName).toLowerCase();
  void refreshBotName() {
    cachedBotName =
        (queries.getBotIdentity()?.name ?? env.botName).toLowerCase();
    log.info('Bot name cache refreshed', extra: {'name': cachedBotName});
  }

  // Wire up identity change callback so the cache stays warm.
  registerBotIdentityOnChanged(refreshBotName);

  // Track chats where the bot spoke last, so the next message is treated as a
  // continuation without requiring an explicit name mention.
  final continuation = GroupContinuation();

  log.info('Dreamfinder is running!', extra: {
    'poll_interval_seconds': _pollIntervalSeconds,
  });

  while (true) {
    try {
      final envelopes = await signalClient.receiveMessages();
      health.recordPoll();

      for (final envelope in envelopes) {
        if (!envelope.hasTextMessage) continue;

        final text = envelope.dataMessage!.message!;
        final isGroup = envelope.isGroupMessage;

        // In group chats, respond when:
        // 1. The bot name is mentioned (whole word), OR
        // 2. The bot was the last speaker (conversation continuation).
        if (isGroup &&
            !continuation.shouldContinue(chatId: envelope.chatId) &&
            !RegExp('\\b${RegExp.escape(cachedBotName)}\\b',
                    caseSensitive: false)
                .hasMatch(text)) {
          continue;
        }

        // Rate limit check — prevents spam from a single user or group.
        if (!rateLimiter.shouldAllow(
          chatId: envelope.chatId,
          senderUuid: envelope.sourceUuid,
        )) {
          log.warning('Rate limited', extra: {
            'sender': envelope.source,
            'chatId': envelope.chatId,
          });
          continue;
        }

        log.info('Message received', extra: {
          'group': isGroup,
          'sender': envelope.source,
          'chatId': envelope.chatId,
        });
        log.debug('Message text', extra: {
          'text': text.length > 200 ? '${text.substring(0, 200)}...' : text,
        });

        try {
          final senderIsAdmin = env.isAdmin(envelope.sourceUuid);
          toolRegistry.setContext(ToolContext(
            senderUuid: envelope.sourceUuid,
            isAdmin: senderIsAdmin,
            chatId: envelope.chatId,
            isGroup: isGroup,
          ));
          final input = AgentInput(
            text: text,
            chatId: envelope.chatId,
            senderUuid: envelope.sourceUuid,
            isAdmin: senderIsAdmin,
            isGroup: isGroup,
          );

          // Retrieve relevant long-term memories for context injection.
          // Skip memories within the conversation history TTL — those are
          // likely still in the sliding window and would waste tokens.
          final memories = memoryRetriever != null
              ? await memoryRetriever.retrieve(
                  text,
                  envelope.chatId,
                  skipRecentMinutes: history.ttl.inMinutes,
                )
              : <MemorySearchResult>[];

          // Fetch upcoming calendar events for awareness.
          final events = calendarRetriever != null
              ? await calendarRetriever.fetchUpcoming()
              : <CalendarEvent>[];

          final response = await agentLoop.processMessage(
            input,
            systemPrompt: buildSystemPrompt(
              input,
              botName: env.botName,
              identity: queries.getBotIdentity(),
              memories: memories,
              events: events,
              eventTimeZone: env.eventTimeZone,
            ),
          );
          health.recordClaudeSuccess();

          if (response.isNotEmpty) {
            log.info('Responding', extra: {
              'chatId': envelope.chatId,
              'length': response.length,
            });
            await signalClient.sendMessage(
              recipient: envelope.chatId,
              message: response,
            );
            // Mark this chat so the next message is treated as a continuation.
            if (isGroup) {
              continuation.recordBotResponse(chatId: envelope.chatId);
            }
            log.debug('Response sent');
          }
        } on Exception catch (e) {
          health.recordError();
          log.error('Error processing message: $e', extra: {
            'chatId': envelope.chatId,
          });

          // Self-heal: if Claude rejects due to malformed history (orphaned
          // tool_result blocks), clear that chat's history and retry once.
          if (e.toString().contains('tool_use_id') ||
              e.toString().contains('tool_result')) {
            log.warning('Clearing corrupt history', extra: {
              'chatId': envelope.chatId,
            });
            history.clearHistory(envelope.chatId);
            messageRepo.deleteConversation(envelope.chatId);
          }

          try {
            await signalClient.sendMessage(
              recipient: envelope.chatId,
              message: 'Something went wrong. Please try again.',
            );
          } on Exception catch (sendErr) {
            log.error('Failed to send error message: $sendErr');
          }
        }
      }
    } on Exception catch (e) {
      health.recordError();
      log.error('Polling error: $e');

      // Auto-recover from signal-cli connection drops by restarting the
      // Docker container and reloading group mappings.
      if (e.toString().contains('Closed unexpectedly') ||
          e.toString().contains('Connection terminated')) {
        log.warning('Signal connection lost — restarting signal-api...');
        try {
          final result = await Process.run('docker', [
            'compose',
            '-f',
            'docker-compose.dart.yml',
            'restart',
            'signal-api',
          ]);
          log.info('signal-api restart', extra: {
            'success': result.exitCode == 0,
          });
          // Wait for the container to come back up with a health check loop.
          var connected = false;
          for (var attempt = 0; attempt < 10; attempt++) {
            await Future<void>.delayed(const Duration(seconds: 3));
            try {
              await signalClient.about();
              connected = true;
              break;
            } on Exception {
              log.info('Waiting for signal-api...', extra: {
                'attempt': attempt + 1,
              });
            }
          }
          if (connected) {
            await signalClient.loadGroupMappings();
            log.info('Reconnected and group mappings reloaded');
          } else {
            log.error('signal-api failed to come back up after 30s');
          }
        } on Exception catch (restartErr) {
          log.error('Failed to restart signal-api: $restartErr');
        }
      }
    }

    history.evictStale();
    rateLimiter.evictStale();
    continuation.evictStale();
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
      if (content is String) {
        sdkMessages.add(anthropic.Message(
          role: anthropic.MessageRole.assistant,
          content: anthropic.MessageContent.text(content),
        ));
      } else if (content is Map<String, dynamic>) {
        // Reconstruct proper Block content from the agent loop's Map format
        // which contains textBlocks and toolUseBlocks.
        final blocks = <anthropic.Block>[];
        final textList = content['textBlocks'] as List<dynamic>? ?? [];
        for (final t in textList) {
          final map = t as Map<String, dynamic>;
          blocks.add(anthropic.Block.text(text: map['text'] as String));
        }
        final toolList = content['toolUseBlocks'] as List<dynamic>? ?? [];
        for (final t in toolList) {
          final map = t as Map<String, dynamic>;
          blocks.add(anthropic.Block.toolUse(
            id: map['id'] as String,
            name: map['name'] as String,
            input: map['input'] as Map<String, dynamic>,
          ));
        }
        sdkMessages.add(anthropic.Message(
          role: anthropic.MessageRole.assistant,
          content: anthropic.MessageContent.blocks(blocks),
        ));
      }
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
