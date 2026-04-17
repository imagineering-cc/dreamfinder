import 'dart:io';
import 'dart:math';

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
import 'package:dreamfinder/src/db/schema.dart';
import 'package:dreamfinder/src/dream/dream_cycle.dart';
import 'package:dreamfinder/src/kickstart/kickstart.dart';
import 'package:dreamfinder/src/kickstart/kickstart_prompt.dart';
import 'package:dreamfinder/src/kickstart/kickstart_state.dart';
import 'package:dreamfinder/src/logging/logger.dart';
import 'package:dreamfinder/src/matrix/matrix_auth.dart';
import 'package:dreamfinder/src/matrix/matrix_client.dart';
import 'package:dreamfinder/src/mcp/mcp_config.dart';
import 'package:dreamfinder/src/mcp/mcp_manager.dart';
import 'package:dreamfinder/src/memory/embedding_backfill.dart';
import 'package:dreamfinder/src/memory/embedding_client.dart';
import 'package:dreamfinder/src/memory/embedding_pipeline.dart';
import 'package:dreamfinder/src/memory/memory_consolidator.dart';
import 'package:dreamfinder/src/memory/memory_record.dart';
import 'package:dreamfinder/src/memory/memory_retriever.dart';
import 'package:dreamfinder/src/memory/summarization_client.dart';
import 'package:dreamfinder/src/session/session.dart';
import 'package:dreamfinder/src/session/session_prompt.dart';
import 'package:dreamfinder/src/session/session_state.dart';
import 'package:dreamfinder/src/session/session_timer.dart';
import 'package:dreamfinder/src/game/game_event_router.dart';
import 'package:dreamfinder/src/livekit/livekit_server_client.dart';
import 'package:dreamfinder/src/tools/bot_identity_tools.dart';
import 'package:dreamfinder/src/tools/chat_config_tools.dart';
import 'package:dreamfinder/src/tools/github_tools.dart';
import 'package:dreamfinder/src/tools/kickstart_tools.dart';
import 'package:dreamfinder/src/tools/memory_tools.dart';
import 'package:dreamfinder/src/tools/radar_tools.dart';
import 'package:dreamfinder/src/tools/session_tools.dart';
import 'package:dreamfinder/src/tools/standup_tools.dart';

/// Maximum backoff for sync retry (30 seconds).
const _maxBackoff = Duration(seconds: 30);

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
    'homeserver': env.matrixHomeserver,
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

  // Authenticate with Matrix homeserver.
  final matrixAuth = MatrixAuth(
    homeserver: env.matrixHomeserver,
    accessToken: env.matrixAccessToken,
    username: env.matrixUsername,
    password: env.matrixPassword,
  );
  final matrixToken = await matrixAuth.getAccessToken();

  final matrixClient = MatrixClient(
    homeserver: env.matrixHomeserver,
    accessToken: matrixToken,
  );

  try {
    final botUserId = await matrixClient.whoAmI();
    log.info('Matrix connected', extra: {'user': botUserId});
  } on Exception catch (e) {
    log.error('Failed to connect to Matrix: $e');
    exit(1);
  }

  final mcpManager = McpManager();

  // Load MCP servers from config file. Servers with unresolved env vars
  // are silently skipped — this lets the same config work across
  // environments (dev without Kan, prod with everything).
  final mcpConfigs = loadMcpConfig();
  if (mcpConfigs.isNotEmpty) {
    for (final config in mcpConfigs) {
      await mcpManager.startServer(config);
    }
  } else {
    // Fallback: no config file, use legacy env-var-based setup.
    if (env.kanEnabled) {
      await mcpManager.startServer(McpServerConfig(
        name: 'kan',
        command: 'node',
        args: <String>['mcp-servers/packages/kan/index.js'],
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
  }

  final serverNames = mcpManager.getServerNames();
  log.info('MCP servers: ${serverNames.isEmpty ? "(none)" : serverNames.join(", ")}');

  // Set up calendar event awareness — optional, enabled when CALENDAR_URL is
  // set and Radicale MCP is running.
  CalendarRetriever? calendarRetriever;
  if (env.calendarUrl != null && serverNames.contains('radicale')) {
    calendarRetriever = CalendarRetriever(
      mcpManager: mcpManager,
      calendarUrl: env.calendarUrl!,
    );
    log.info('Calendar awareness enabled', extra: {'url': env.calendarUrl});
  }

  final queries = Queries(database);

  // Expose recent memories via HTTP for the embodied avatar frontend.
  // This uses a simple recency query — no Voyage AI call needed.
  health.getRecentMemories =
      (String chatId, {int limit = 5}) =>
          queries.getRecentVisibleMemories(chatId, limit: limit);

  // Expose recent conversation history for the voice brain bridge.
  // Returns raw message rows; the health check handler groups by chat_id.
  health.getRecentConversations =
      ({int limit = 20, String? excludeChatId}) =>
          _getRecentConversations(database, limit: limit, excludeChatId: excludeChatId);

  final toolRegistry = ToolRegistry();
  toolRegistry.setMcpManager(mcpManager);
  registerBotIdentityTools(toolRegistry, queries);
  registerChatConfigTools(toolRegistry, queries);
  registerStandupTools(toolRegistry, queries);
  final kickstartState = KickstartState(queries: queries);
  registerKickstartTools(
    toolRegistry,
    kickstartState,
    sendGroupMessage: (roomId, message) =>
        matrixClient.sendMessage(roomId: roomId, message: message),
  );
  // LiveKit server client for the AITW game bridge (optional).
  final liveKitClient = env.liveKitEnabled
      ? LiveKitServerClient(
          serverUrl: env.liveKitUrl!,
          apiKey: env.liveKitApiKey!,
          apiSecret: env.liveKitApiSecret!,
        )
      : null;
  if (liveKitClient != null) {
    log.info('LiveKit game bridge enabled');
  }

  /// Routes a message to the correct transport based on chatId prefix.
  /// Game rooms use `game:$roomName`, Matrix rooms start with `!`.
  Future<void> sendToGroup(String groupId, String message) async {
    if (groupId.startsWith('game:') && liveKitClient != null) {
      final roomName = groupId.substring(5);
      await liveKitClient.sendJson(
        room: roomName,
        topic: 'chat-response',
        payload: <String, Object?>{
          'text': message,
          'senderName': env.botName,
          'senderId': 'bot-dreamfinder',
          'id': 'sys-${DateTime.now().millisecondsSinceEpoch}',
        },
      );
    } else {
      await matrixClient.sendMessage(roomId: groupId, message: message);
    }
  }

  final sessionState = SessionState(queries: queries);
  final sessionTimer = SessionTimer(
    sessionState: sessionState,
    onPhaseTransition: (groupId, newPhase) async {
      final message = _sessionTransitionMessage(newPhase);
      await sendToGroup(groupId, message);
      log.info('Session phase transition', extra: {
        'room': groupId,
        'phase': newPhase.label,
      });
    },
  );
  registerSessionTools(
    toolRegistry,
    sessionState,
    sendGroupMessage: sendToGroup,
    sessionTimer: sessionTimer,
  );
  registerGitHubTools(
    toolRegistry,
    token: env.githubToken,
    defaultRepo: env.githubRepo ?? 'imagineering-cc/dreamfinder',
  );
  registerRadarTools(
    toolRegistry,
    queries: queries,
    token: env.githubToken,
  );
  if (env.githubEnabled) {
    log.info('GitHub tools enabled (includes Repo Radar)');
  }
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
    // Expose memory system via HTTP for the embodied avatar frontend.
    health.memoryRetriever = memoryRetriever;
    health.embeddingPipeline = embeddingPipeline;
    log.info('RAG memory system enabled (Voyage AI)');
  } else {
    log.info('RAG memory system disabled (no VOYAGE_API_KEY)');
  }

  // Set API key for all authenticated endpoints (memory API + game bridge).
  // This must be outside the Voyage block — the game bridge needs auth
  // even when RAG is disabled.
  health.apiKey = env.apiKey;

  registerMemoryTools(
    toolRegistry,
    embeddingPipeline,
    memoryRetriever,
    mcpManager,
  );

  // Set up Anthropic client — OAuth (Claude Max) or API key.
  OAuthTokenManager? oauthManager;
  anthropic.AnthropicClient anthropicClient;

  if (env.useOAuth) {
    oauthManager = OAuthTokenManager(
      queries: queries,
      log: BotLogger(name: 'OAuth', level: LogLevel.fromString(env.logLevel)),
      initialRefreshToken: env.claudeRefreshToken,
    );
    anthropicClient = anthropic.AnthropicClient(apiKey: '');
    log.info('Auth mode: OAuth (Claude Max)');
  } else {
    anthropicClient = anthropic.AnthropicClient(apiKey: env.anthropicApiKey!);
    log.info('Auth mode: API key');
  }

  // Track the last access token so we only recreate the client on refresh.
  // ignore: no_leading_underscores_for_local_identifiers
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
    onTyping: (chatId) =>
        matrixClient.sendTypingIndicator(roomId: chatId),
    embeddingPipeline: embeddingPipeline,
  );

  // Wire up memory consolidator now that the Anthropic client exists.
  if (env.voyageEnabled && voyageClient != null) {
    final summarizer = SummarizationClient(
      createSummarization: (prompt) async {
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

  /// Sends a message to a Matrix room (shared callback for scheduler,
  /// dream cycle, deploy announcer, and kickstart tools).
  Future<void> sendToRoom(String roomId, String message) async {
    await matrixClient.sendMessage(roomId: roomId, message: message);
  }

  final rateLimiter = RateLimiter();

  // Dream cycle orchestrator — triggered by "goodnight" messages.
  final dreamCycle = DreamCycle(
    queries: queries,
    messageRepo: messageRepo,
    agentLoop: agentLoop,
    toolRegistry: toolRegistry,
    sendMessage: sendToRoom,
    botName: env.botName,
    buildSystemPrompt: (input) => buildSystemPrompt(
      input,
      botName: env.botName,
      identity: queries.getBotIdentity(),
    ),
  );

  final scheduler = Scheduler(
    queries: queries,
    sendMessage: sendToRoom,
    backfill: embeddingBackfill,
    consolidator: memoryConsolidator,
    triggerDream: ({
      required String groupId,
      required String triggeredByUuid,
      required String date,
    }) =>
        dreamCycle.trigger(
      groupId: groupId,
      triggeredByUuid: triggeredByUuid,
      date: date,
    ),
    composeViaAgent: (groupId, taskDescription) async {
      final input = AgentInput(
        text: taskDescription,
        chatId: groupId,
        senderId: 'system',
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
    composeWithTools: (groupId, taskDescription) async {
      final input = AgentInput(
        text: taskDescription,
        chatId: groupId,
        senderId: 'system',
        isAdmin: true,
        isProactive: true,
      );

      // Retrieve memories and events — same as the normal message path.
      final memories = memoryRetriever != null
          ? await memoryRetriever
                .retrieve(taskDescription, groupId)
                .timeout(
                  const Duration(seconds: 10),
                  onTimeout: () => <MemorySearchResult>[],
                )
          : <MemorySearchResult>[];

      final events = calendarRetriever != null
          ? await calendarRetriever.fetchUpcoming().timeout(
                const Duration(seconds: 10),
                onTimeout: () => <CalendarEvent>[],
              )
          : <CalendarEvent>[];

      return agentLoop.processMessage(
        input,
        systemPrompt: _buildFullSystemPrompt(
          input: input,
          env: env,
          queries: queries,
          memories: memories,
          events: events,
          kickstartState: kickstartState,
          sessionState: sessionState,
          chatId: groupId,
          senderId: 'system',
          isGroup: true,
        ),
        // Task radar queries multiple MCP sources (Kan, Outline, Radicale,
        // memory) — 10 default rounds may be tight for cross-source synthesis.
        maxToolRounds: 20,
      );
    },
  );
  scheduler.start();
  log.info('Scheduler started');

  // Wire the AITW game event bridge (if LiveKit is configured).
  if (liveKitClient != null) {
    final gameRouter = GameEventRouter(
      agentLoop: agentLoop,
      toolRegistry: toolRegistry,
      liveKitClient: liveKitClient,
      sessionState: sessionState,
      sessionTimer: sessionTimer,
      botName: env.botName,
      log: BotLogger(
        name: 'Game',
        level: LogLevel.fromString(env.logLevel),
      ),
      buildSystemPrompt: ({
        required input,
        required chatId,
        required senderId,
        required isGroup,
      }) =>
          _buildFullSystemPrompt(
        input: input,
        env: env,
        queries: queries,
        memories: const [],
        events: const [],
        kickstartState: kickstartState,
        sessionState: sessionState,
        chatId: chatId,
        senderId: senderId,
        isGroup: isGroup,
      ),
    );
    health.onGameEvent = gameRouter.handleRequest;
    log.info('Game event bridge ready');
  }

  // Announce deploy if version changed.
  final announceGroupId = env.deployAnnounceGroupId;
  if (announceGroupId != null && appChangelog.trim().isNotEmpty) {
    final announcer = DeployAnnouncer(
      queries: queries,
      composeViaAgent: (groupId, taskDescription) async {
        final input = AgentInput(
          text: taskDescription,
          chatId: groupId,
          senderId: 'system',
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
      sendMessage: sendToRoom,
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
    sessionTimer.dispose();
    liveKitClient?.close();
    health.stop();
    database.close();
    mcpManager.shutdown();
    anthropicClient.endSession();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen((_) => shutdown());
  ProcessSignal.sigterm.watch().listen((_) => shutdown());

  // Cache the bot name for mention detection — avoids a DB hit per message.
  var cachedBotName =
      (queries.getBotIdentity()?.name ?? env.botName).toLowerCase();
  void refreshBotName() {
    cachedBotName =
        (queries.getBotIdentity()?.name ?? env.botName).toLowerCase();
    log.info('Bot name cache refreshed', extra: {'name': cachedBotName});
  }

  registerBotIdentityOnChanged(refreshBotName);

  final continuation = GroupContinuation();

  // Build the ignore set for rooms to skip.
  final ignoreRooms = env.matrixIgnoreRooms.toSet();

  // Rooms where the bot responds to every message (no mention required).
  final alwaysRespondRooms = env.matrixAlwaysRespondRooms.toSet();

  // Retrieve the stored sync token for resumption across restarts.
  var nextBatch = queries.getMetadata('matrix_next_batch');
  if (nextBatch != null) {
    log.info('Resuming sync', extra: {'since': nextBatch});
  } else {
    log.info('Initial sync — skipping old timeline events');
  }

  final botUserId = await matrixClient.whoAmI();
  log.info('Dreamfinder is running!', extra: {'user': botUserId});

  var backoff = const Duration(seconds: 1);

  // ─── Matrix sync loop ──────────────────────────────────────────────────
  while (true) {
    try {
      final sync = await matrixClient.sync(
        since: nextBatch,
        timeout: 30000,
      );
      health.recordPoll();
      backoff = const Duration(seconds: 1); // Reset on success.

      if (sync.events.isNotEmpty || sync.invites.isNotEmpty) {
        log.debug('Sync returned', extra: {
          'events': sync.events.length,
          'invites': sync.invites.length,
        });
      }

      // Persist sync token for resumption.
      nextBatch = sync.nextBatch;
      queries.setMetadata('matrix_next_batch', nextBatch);

      // Auto-join on invite.
      for (final invite in sync.invites) {
        log.info('Invited to room', extra: {
          'room': invite.roomId,
          'by': invite.inviter,
        });
        try {
          await matrixClient.joinRoom(invite.roomId);
          log.info('Joined room', extra: {'room': invite.roomId});
        } on Exception catch (e) {
          log.warning('Failed to join room: $e', extra: {
            'room': invite.roomId,
          });
        }
      }

      // Process timeline events.
      for (final event in sync.events) {
        if (event.sender == botUserId) {
          health.recordMessageDropped('own_message');
          continue;
        }
        if (ignoreRooms.contains(event.roomId)) {
          health.recordMessageDropped('ignored_room');
          continue;
        }
        // Welcome new members joining a group room.
        if (event.isMemberJoin && !matrixClient.isDm(event.roomId)) {
          final displayName =
              event.memberDisplayName ?? event.sender.split(':').first.substring(1);
          log.info('New member joined', extra: {
            'room': event.roomId,
            'user': event.sender,
            'name': displayName,
          });

          try {
            await matrixClient.sendMessage(
              roomId: event.roomId,
              message: 'Welcome $displayName! '
                  "Send me a DM and I'll get you set up. ✨",
            );
          } on Exception catch (e) {
            log.warning('Failed to send welcome message: $e');
          }
          health.recordMessageDropped('member_join');
          continue;
        }

        if (!event.hasTextMessage) {
          health.recordMessageDropped('no_text');
          continue;
        }

        final text = event.body!;
        final isDm = matrixClient.isDm(event.roomId);
        final isGroup = !isDm;

        // In group chats, respond when:
        // 1. The room is in the always-respond list, OR
        // 2. The bot is mentioned (pill or name), OR
        // 3. The bot was the last speaker (conversation continuation).
        if (isGroup &&
            !alwaysRespondRooms.contains(event.roomId) &&
            !continuation.shouldContinue(chatId: event.roomId) &&
            !matrixClient.isMentioned(
              text: text,
              formattedBody: event.formattedBody,
              botDisplayName: cachedBotName,
            )) {
          health.recordMessageDropped('not_mentioned');
          continue;
        }

        // Rate limit check.
        if (!rateLimiter.shouldAllow(
          chatId: event.roomId,
          senderId: event.sender,
          isDm: isDm,
        )) {
          log.warning('Rate limited', extra: {
            'sender': event.sender,
            'room': event.roomId,
          });
          health.recordMessageDropped('rate_limited');
          continue;
        }

        log.info('Message received', extra: {
          'group': isGroup,
          'sender': event.sender,
          'room': event.roomId,
        });
        log.debug('Message text', extra: {
          'text': text.length > 200 ? '${text.substring(0, 200)}...' : text,
        });

        try {
          final senderIsAdmin = env.isAdmin(event.sender);
          toolRegistry.setContext(ToolContext(
            senderId: event.sender,
            isAdmin: senderIsAdmin,
            chatId: event.roomId,
            isGroup: isGroup,
          ));
          final input = AgentInput(
            text: text,
            chatId: event.roomId,
            senderId: event.sender,
            isAdmin: senderIsAdmin,
            isGroup: isGroup,
          );

          // Retrieve relevant long-term memories for context injection.
          // Timeout gracefully — empty results are better than a hung loop.
          final memories = memoryRetriever != null
              ? await memoryRetriever
                    .retrieve(
                      text,
                      event.roomId,
                      skipRecentMinutes: history.ttl.inMinutes,
                    )
                    .timeout(
                      const Duration(seconds: 10),
                      onTimeout: () => <MemorySearchResult>[],
                    )
              : <MemorySearchResult>[];

          // Fetch upcoming calendar events for awareness.
          final events = calendarRetriever != null
              ? await calendarRetriever.fetchUpcoming().timeout(
                    const Duration(seconds: 10),
                    onTimeout: () => <CalendarEvent>[],
                  )
              : <CalendarEvent>[];

          // Detect kickstart triggers — any group member + trigger phrase.
          // Redirect to DMs: ack in group, then run agent loop in DM room.
          if (isGroup &&
              isKickstartMessage(text) &&
              !kickstartState.isKickstartActive(event.roomId)) {
            kickstartState.startKickstart(
              event.roomId,
              initiatorUuid: event.sender,
            );
            log.info('Kickstart started (DM flow)', extra: {
              'room': event.roomId,
              'sender': event.sender,
            });
            await matrixClient.sendMessage(
              roomId: event.roomId,
              message: "Send me a DM to get started! I'll walk you through "
                  'setting everything up. ✨',
            );
            // The user DMs Dreamfinder on their platform (Signal, Telegram,
            // Discord, etc.). The bridge relays it to Matrix as a DM, and
            // the kickstart state (keyed by sender) picks up the flow.
            health.recordMessageDropped('kickstart_dm_redirect');
            continue;
          }

          // Detect session triggers — group-only, no DM redirect.
          if (isGroup &&
              isSessionMessage(text) &&
              !sessionState.isSessionActive(event.roomId)) {
            sessionState.startSession(
              event.roomId,
              initiatorId: event.sender,
            );
            // Start the phase timer — Dreamfinder now keeps time autonomously.
            sessionTimer.startTimer(event.roomId, SessionPhase.pitch);
            log.info('Session started', extra: {
              'room': event.roomId,
              'sender': event.sender,
            });
            // Don't `continue` — let the agent loop handle the first
            // response (pitch phase facilitation) with the session
            // prompt injected below.
          }

          // Build system prompt — append kickstart/session sections.
          final systemPromptText = _buildFullSystemPrompt(
            input: input,
            env: env,
            queries: queries,
            memories: memories,
            events: events,
            kickstartState: kickstartState,
            sessionState: sessionState,
            chatId: event.roomId,
            senderId: event.sender,
            isGroup: isGroup,
          );

          health.recordProcessingStart();
          final stopwatch = Stopwatch()..start();
          final response = await agentLoop
              .processMessage(
                input,
                systemPrompt: systemPromptText,
              )
              .timeout(const Duration(minutes: 3));
          health.recordClaudeSuccess();

          if (response.isNotEmpty) {
            log.info('Responding', extra: {
              'room': event.roomId,
              'length': response.length,
            });
            await matrixClient.sendMessage(
              roomId: event.roomId,
              message: response,
            );
            if (isGroup) {
              continuation.recordBotResponse(chatId: event.roomId);
            }

            // Check for goodnight messages in group chats → trigger dream.
            if (isGroup && isGoodnightMessage(text)) {
              final today =
                  DateTime.now().toUtc().toIso8601String().split('T').first;
              final started = dreamCycle.trigger(
                groupId: event.roomId,
                triggeredByUuid: event.sender,
                date: today,
              );
              if (started) {
                log.info('Dream cycle triggered', extra: {
                  'room': event.roomId,
                  'date': today,
                });
              }
            }
          }
          stopwatch.stop();
          health.recordMessageProcessed();
          log.info('Message processed', extra: {
            'room': event.roomId,
            'elapsed_ms': stopwatch.elapsedMilliseconds,
          });
        } on Object catch (e, st) {
          health.recordError();
          log.error('Error processing message: $e', extra: {
            'room': event.roomId,
            'stackTrace': '$st',
          });

          // Self-heal: clear corrupt conversation history.
          if (e.toString().contains('tool_use_id') ||
              e.toString().contains('tool_result')) {
            log.warning('Clearing corrupt history', extra: {
              'room': event.roomId,
            });
            history.clearHistory(event.roomId);
            messageRepo.deleteConversation(event.roomId);
          }

          try {
            await matrixClient.sendMessage(
              roomId: event.roomId,
              message: 'Something went wrong. Please try again.',
            );
          } on Object catch (sendErr) {
            log.error('Failed to send error message: $sendErr');
          }
        } finally {
          health.recordProcessingEnd();
        }
      }
    } on Object catch (e, st) {
      health.recordError();
      log.error('Sync error: $e', extra: {'stackTrace': '$st'});

      // Exponential backoff on sync failure (1s → 2s → 4s → ... → 30s).
      await Future<void>.delayed(backoff);
      backoff = Duration(
        milliseconds: min(backoff.inMilliseconds * 2, _maxBackoff.inMilliseconds),
      );
      continue;
    }

    history.evictStale();
    rateLimiter.evictStale();
    continuation.evictStale();
    // No delay needed — Matrix sync long-polls server-side.
  }
}

/// Fetches recent messages across all conversations for the voice brain bridge.
///
/// Returns raw row maps ordered by created_at DESC, limited to [limit] total
/// messages. Messages from [excludeChatId] are filtered out if provided.
/// Only includes text messages (skips tool-use/tool-result JSON blocks).
List<Map<String, Object?>> _getRecentConversations(
  BotDatabase database, {
  int limit = 20,
  String? excludeChatId,
}) {
  final buffer = StringBuffer(
    'SELECT chat_id, role, content, sender_name, created_at '
    'FROM messages ',
  );
  final params = <Object?>[];

  if (excludeChatId != null) {
    buffer.write('WHERE chat_id != ? ');
    params.add(excludeChatId);
  }

  buffer.write('ORDER BY created_at DESC LIMIT ?');
  params.add(limit);

  final rows = database.handle.select(buffer.toString(), params);

  // Filter out tool-use/tool-result blocks (JSON content starting with [ or {)
  // and return in chronological order (reverse the DESC query).
  return [
    for (final row in rows.reversed)
      if (row['content'] is String &&
          !(row['content'] as String).startsWith('[') &&
          !(row['content'] as String).startsWith('{'))
        <String, Object?>{
          'chat_id': row['chat_id'] as String,
          'role': row['role'] as String,
          'content': row['content'] as String,
          'sender_name': row['sender_name'] as String?,
          'created_at': row['created_at'] as String,
        },
  ];
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
      model: const anthropic.Model.modelId('claude-haiku-4-5-20251001'),
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
    inputTokens: response.usage?.inputTokens ?? 0,
    outputTokens: response.usage?.outputTokens ?? 0,
  );
}

/// Builds the full system prompt, appending the kickstart and/or session
/// section if either is active for this chat (group) or sender (DM).
String _buildFullSystemPrompt({
  required AgentInput input,
  required Env env,
  required Queries queries,
  required List<MemorySearchResult> memories,
  required List<CalendarEvent> events,
  required KickstartState kickstartState,
  required SessionState sessionState,
  required String chatId,
  required String senderId,
  required bool isGroup,
}) {
  // Build tracked repo summaries for the Repo Radar system prompt section.
  final trackedRepos = queries.getAllTrackedRepos().map((r) {
    return TrackedRepoSummary(
      repo: r.repo,
      reason: r.reason,
      starred: r.starred,
    );
  }).toList();

  final identity = queries.getBotIdentity();
  final personalityTraits =
      identity != null ? queries.getPersonalityTraits(identity.id) : const <PersonalityTrait>[];
  var prompt = buildSystemPrompt(
    input,
    botName: env.botName,
    identity: identity,
    personalityTraits: personalityTraits,
    memories: memories,
    events: events,
    eventTimeZone: env.eventTimeZone,
    trackedRepos: trackedRepos,
  );

  // Kickstart prompt injection — check group key or DM reverse-lookup.
  KickstartStep? kickstartStep;
  String? kickstartGroupId;

  if (isGroup) {
    kickstartStep = kickstartState.getActiveKickstart(chatId);
    kickstartGroupId = chatId;
  } else {
    final info = kickstartState.getKickstartForUser(senderId);
    kickstartStep = info?.step;
    kickstartGroupId = info?.groupId;
  }

  if (kickstartStep != null && kickstartGroupId != null) {
    prompt += buildKickstartPromptSection(kickstartStep, kickstartGroupId);
  }

  // Session prompt injection — group-only (no DM sessions).
  if (isGroup) {
    final sessionPhase = sessionState.getActiveSession(chatId);
    if (sessionPhase != null) {
      prompt += buildSessionPromptSection(sessionPhase, chatId);
    }
  }

  return prompt;
}

/// Returns a short, clear transition message for each phase change.
///
/// These are intentionally templated rather than LLM-composed — phase
/// transitions should be predictable and crisp. The agent's natural
/// personality comes through in its response to the *next* participant
/// message, which will have the new phase's prompt injected.
String _sessionTransitionMessage(SessionPhase newPhase) => switch (newPhase) {
      SessionPhase.pitch =>
        // Shouldn't happen (pitch is the first phase), but handle gracefully.
        '🎤 Session starting! What is everyone working on today?',
      SessionPhase.build1 =>
        '⏱️ Great pitches! Build 1 starting now — 25 minutes on the clock. '
            'Go build something.',
      SessionPhase.chat1 =>
        '⏱️ Build 1 complete! Take 5 — how\'s everyone going?',
      SessionPhase.build2 =>
        '⏱️ Back to it! Build 2 starting — 25 minutes.',
      SessionPhase.chat2 =>
        '⏱️ Build 2 done! Check-in time — what\'s working, what\'s not?',
      SessionPhase.build3 =>
        '⏱️ Final build! 25 minutes — polish, test, prep your demo.',
      SessionPhase.chat3 =>
        '⏱️ Build 3 complete! Last check-in before demos. '
            'How did it go? What are you showing?',
      SessionPhase.demo =>
        '🎪 Demo time! Who wants to go first?',
    };
