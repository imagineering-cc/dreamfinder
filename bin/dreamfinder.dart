import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:anthropic_sdk_dart/anthropic_sdk_dart.dart' as anthropic;
import 'package:dreamfinder/src/agent/agent_loop.dart';
import 'package:dreamfinder/src/agent/calendar_retriever.dart';
import 'package:dreamfinder/src/agent/claude_error.dart';
import 'package:dreamfinder/src/agent/conversation_history.dart';
import 'package:dreamfinder/src/agent/system_prompt.dart';
import 'package:dreamfinder/src/agent/tool_registry.dart';
import 'package:dreamfinder/src/bot/alerter.dart';
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
import 'package:dreamfinder/src/game/game_event_router.dart';
import 'package:dreamfinder/src/immune/boot_checks.dart';
import 'package:dreamfinder/src/immune/golden_seeder.dart';
import 'package:dreamfinder/src/immune/golden_sentinels.dart';
import 'package:dreamfinder/src/immune/probe.dart';
import 'package:dreamfinder/src/immune/probe_registry.dart';
import 'package:dreamfinder/src/immune/probes/auth_probe.dart';
import 'package:dreamfinder/src/immune/probes/calendar_probe.dart';
import 'package:dreamfinder/src/immune/probes/content_integrity_probe.dart';
import 'package:dreamfinder/src/immune/probes/deep_search_probe.dart';
import 'package:dreamfinder/src/immune/probes/rag_probe.dart';
import 'package:dreamfinder/src/immune/sentinel.dart';
import 'package:dreamfinder/src/kickstart/kickstart.dart';
import 'package:dreamfinder/src/kickstart/kickstart_prompt.dart';
import 'package:dreamfinder/src/kickstart/kickstart_state.dart';
import 'package:dreamfinder/src/livekit/livekit_server_client.dart';
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
import 'package:dreamfinder/src/tools/bot_identity_tools.dart';
import 'package:dreamfinder/src/tools/chat_config_tools.dart';
import 'package:dreamfinder/src/tools/cli_tools.dart';
import 'package:dreamfinder/src/tools/github_tools.dart';
import 'package:dreamfinder/src/tools/kickstart_tools.dart';
import 'package:dreamfinder/src/tools/lore_tools.dart';
import 'package:dreamfinder/src/tools/memory_tools.dart';
import 'package:dreamfinder/src/tools/messaging_tools.dart';
import 'package:dreamfinder/src/tools/radar_tools.dart';
import 'package:dreamfinder/src/tools/session_tools.dart';
import 'package:dreamfinder/src/tools/standup_tools.dart';
import 'package:timezone/data/latest.dart' as tzdata;

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
    // Bridge appservice bots don't count toward DM detection — this is what
    // makes bridged 1:1 portal rooms (bot + remote ghost + bridge bot)
    // classify as DMs instead of groups.
    bridgeBotIds: env.bridgeBotIds.toSet(),
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
  }

  final serverNames = mcpManager.getServerNames();
  log.info(
      'MCP servers: ${serverNames.isEmpty ? "(none)" : serverNames.join(", ")}');

  // Set up calendar event awareness — optional, enabled when CALENDAR_URL is
  // set. Calendar reads go through the vendored `radicale` CLI (not the MCP),
  // so this no longer depends on an MCP server being up.
  CalendarRetriever? calendarRetriever;
  if (env.calendarUrl != null &&
      env.radicaleBaseUrl != null &&
      env.radicaleUsername != null &&
      env.radicalePassword != null) {
    calendarRetriever = CalendarRetriever(
      calendarUrl: env.calendarUrl!,
      radicaleBaseUrl: env.radicaleBaseUrl!,
      radicaleUsername: env.radicaleUsername!,
      radicalePassword: env.radicalePassword!,
    );
    log.info('Calendar awareness enabled', extra: {'url': env.calendarUrl});
  }

  final queries = Queries(database);

  // Expose recent memories via HTTP for the embodied avatar frontend.
  // This uses a simple recency query — no Voyage AI call needed.
  health.getRecentMemories = queries.getRecentVisibleMemories;

  // Expose recent conversation history for the voice brain bridge.
  // Returns raw message rows; the health check handler groups by chat_id.
  health.getRecentConversations = ({int limit = 20, String? excludeChatId}) =>
      _getRecentConversations(database,
          limit: limit, excludeChatId: excludeChatId);

  final toolRegistry = ToolRegistry();
  toolRegistry.setMcpManager(mcpManager);
  registerBotIdentityTools(toolRegistry, queries);
  registerChatConfigTools(toolRegistry, queries);
  registerStandupTools(toolRegistry, queries);
  // Kan + Outline are driven via the `run_cli` executor (vendored CLIs),
  // not MCP servers — one tool, full CLI surface, including onboarding.
  registerCliTools(
    toolRegistry,
    kanApiKey: env.kanApiKey,
    kanBaseUrl: env.kanBaseUrl,
    outlineApiKey: env.outlineApiKey,
    outlineBaseUrl: env.outlineBaseUrl,
    radicaleBaseUrl: env.radicaleBaseUrl,
    radicaleUsername: env.radicaleUsername,
    radicalePassword: env.radicalePassword,
  );
  // Proactive lore capture — quietly append durable community stories to the
  // Outline Lore Inbox (dedup'd), so River builds the community's memory
  // without having to reply in chat.
  registerLoreTools(
    toolRegistry,
    queries,
    outlineApiKey: env.outlineApiKey,
    outlineBaseUrl: env.outlineBaseUrl,
  );
  // Proactive DM tools: Matrix-native dm_user always; start_private_chat
  // platforms appear iff their bridge management room is configured AND
  // bridge bot identities are set (the bridge bot ID authenticates the
  // bridge's reply to start-chat — the tool refuses to exist without it).
  registerMessagingTools(
    toolRegistry,
    matrixClient,
    whatsappManagementRoom: env.whatsappManagementRoom,
    telegramManagementRoom: env.telegramManagementRoom,
    signalManagementRoom: env.signalManagementRoom,
    discordManagementRoom: env.discordManagementRoom,
    bridgeBotIds: env.bridgeBotIds.toSet(),
  );
  final proactivePlatforms = <String, String?>{
    'whatsapp': env.whatsappManagementRoom,
    'telegram': env.telegramManagementRoom,
    'signal': env.signalManagementRoom,
    'discord': env.discordManagementRoom,
  }..removeWhere((_, room) => room == null || room.isEmpty);
  if (proactivePlatforms.isNotEmpty && env.bridgeBotIds.isNotEmpty) {
    log.info('Proactive bridged DM enabled', extra: {
      'platforms': proactivePlatforms.keys.toList(),
    });
  }
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
      loadMemories: queries.getVisibleMemories,
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

  // deep_search fans out to Outline + Kan via the vendored CLIs (same path as
  // run_cli), not MCP — the Outline/Kan MCP servers were retired in the run_cli
  // migration. Outline arm needs its creds; Kan arm also needs a workspace id.
  registerMemoryTools(
    toolRegistry,
    embeddingPipeline,
    memoryRetriever,
    outlineApiKey: env.outlineApiKey,
    outlineBaseUrl: env.outlineBaseUrl,
    kanApiKey: env.kanApiKey,
    kanBaseUrl: env.kanBaseUrl,
    kanWorkspaceId: env.kanWorkspaceId,
  );

  // Set up Anthropic client. Auth precedence (most→least robust):
  //   1. Long-lived Claude Code OAuth token (direct Bearer, no refresh)
  //   2. Claude Max refresh-token rotation (OAuthTokenManager)
  //   3. Metered API key
  OAuthTokenManager? oauthManager;
  anthropic.AnthropicClient anthropicClient;

  if (env.useDirectBearer) {
    // A `claude setup-token` credential: used directly as a Bearer header with
    // no exchange. Static for the token's ~1y lifetime — never needs refresh.
    anthropicClient = anthropic.AnthropicClient(
      apiKey: '',
      headers: {
        'Authorization': 'Bearer ${env.claudeCodeOAuthToken}',
        'anthropic-beta': 'oauth-2025-04-20',
      },
    );
    log.info('Auth mode: OAuth (Claude Code long-lived token)');
  } else if (env.useOAuth) {
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

  // Once a bad OAuth refresh token forces a fallback to the API key, we stay on
  // the API key (don't thrash back to the broken OAuth path every call).
  var usingApiKeyFallback = false;

  /// Human-readable auth mode for alerts/logs.
  String authModeLabel() {
    if (usingApiKeyFallback) return 'API key (OAuth fallback)';
    if (env.useDirectBearer) return 'OAuth (Claude Code token)';
    return env.useOAuth ? 'OAuth (Claude Max)' : 'API key';
  }

  // The alerter escalates unrecoverable brain failures. Constructed before the
  // agent loop so the resilient call wrapper can reach it. `sendToRoom` is
  // assigned just below (it's defined a few lines down); we wire it via a late
  // indirection so the alerter can be a `final`.
  late final Future<void> Function(String, String) sendToRoomRef;
  final alerter = Alerter(
    notifyUrl: env.notifyUrl,
    notifyApiKey: env.notifyApiKey,
    announceRoomId: env.deployAnnounceGroupId,
    authModeLabel: authModeLabel(),
    sendToRoom: (room, msg) => sendToRoomRef(room, msg),
    log: BotLogger(name: 'Alerter', level: LogLevel.fromString(env.logLevel)),
  );

  /// Ensures [anthropicClient] is configured for the current auth mode.
  ///
  /// Refreshes the OAuth access token (recreating the client only when the
  /// token rotates) unless we've fallen back to the API key.
  Future<void> ensureClient() async {
    if (oauthManager != null && !usingApiKeyFallback) {
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
  }

  /// Switches [anthropicClient] to the API key after an OAuth auth failure.
  void fallBackToApiKey() {
    usingApiKeyFallback = true;
    anthropicClient = anthropic.AnthropicClient(apiKey: env.anthropicApiKey!);
    alerter.authModeLabel = authModeLabel();
    log.warning(
      'OAuth auth failed — falling back to API key for subsequent calls. '
      'River stays online on the metered API instead of going dark.',
    );
  }

  /// Resilient Claude call: refreshes/repairs auth, retries transient errors
  /// with exponential backoff (1s/2s/4s), falls back OAuth→API-key on auth
  /// failures, and records brain health on every outcome. Non-retryable
  /// `billing`/`auth`/`other` errors are re-thrown (classified) for the caller
  /// to escalate.
  Future<AgentResponse> resilientCreateMessage(
    List<AgentMessage> messages,
    List<ToolDefinition> tools,
    String systemPrompt,
  ) async {
    const maxAttempts = 3;
    var attempt = 0;
    while (true) {
      attempt++;
      try {
        await ensureClient();
        final response =
            await _callClaude(anthropicClient, messages, tools, systemPrompt);
        health.recordClaudeSuccess();
        return response;
      } on Object catch (e) {
        final kind = classifyClaudeError(e);
        final short = _shortError(e);

        // Auth failure under OAuth → degrade to API key and retry once
        // immediately on the new client.
        if (shouldFallBackToApiKey(
          kind: kind,
          oauthActive: oauthManager != null || env.useDirectBearer,
          alreadyFellBack: usingApiKeyFallback,
          hasApiKey:
              env.anthropicApiKey != null && env.anthropicApiKey!.isNotEmpty,
        )) {
          fallBackToApiKey();
          continue; // retry immediately on the API-key client
        }

        if (kind.isRetryable && attempt < maxAttempts) {
          final backoff = Duration(seconds: 1 << (attempt - 1)); // 1,2,4s
          log.warning('Transient Claude error — retrying', extra: {
            'attempt': attempt,
            'backoff_ms': backoff.inMilliseconds,
            'error': short,
          });
          await Future<void>.delayed(backoff);
          continue;
        }

        // Out of retries or non-retryable. Record brain health here (single
        // source of truth) and throw a tagged failure so the main loop can
        // escalate without re-classifying or double-counting the error.
        health.recordClaudeError(kind: kind.name, message: short);
        throw ClaudeCallFailure(kind, e);
      }
    }
  }

  final agentLoop = AgentLoop(
    createMessage: resilientCreateMessage,
    toolRegistry: toolRegistry,
    history: history,
    onTyping: (chatId) => matrixClient.sendTypingIndicator(roomId: chatId),
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

  // Back-fill the alerter's in-room sender now that sendToRoom exists.
  sendToRoomRef = sendToRoom;

  final rateLimiter = RateLimiter(
    perUserCooldown: Duration(seconds: env.rateLimitPerUserSeconds),
    perGroupWindow: Duration(seconds: env.rateLimitGroupWindowSeconds),
    maxGroupMessages: env.rateLimitGroupMax,
  );

  // Dream cycle orchestrator — triggered by "goodnight" messages.
  final dreamCycle = DreamCycle(
    queries: queries,
    messageRepo: messageRepo,
    agentLoop: agentLoop,
    toolRegistry: toolRegistry,
    sendMessage: sendToRoom,
    botName: env.botName,
    buildSystemPrompt: (input) {
      final id = queries.getBotIdentity();
      return buildSystemPrompt(
        input,
        botName: env.botName,
        identity: id,
        personalityTraits:
            id != null ? queries.getPersonalityTraits(id.id) : const [],
      );
    },
  );

  // --- Immune system (self-healer sensing spine) ---
  // Boot hard invariants ALWAYS run: withhold readiness on violation rather
  // than silently serving (e.g. metered-drift). Semantic probes are gated on
  // IMMUNE_PROBES_ENABLED (ships dark). See design/river-immune-system.html.
  final maintenanceMode = MaintenanceMode.fromEnv(env.maintenanceMode);
  try {
    assertHardInvariants(env, maintenanceMode: maintenanceMode);
    health.markReady();
  } on HardInvariantViolation catch (e) {
    log.error(
      'Boot hard invariant violated — withholding readiness',
      extra: {'error': e.message},
    );
    unawaited(
      alerter.escalate(kind: 'boot_hard_invariant', message: e.message),
    );
  }

  ProbeRegistry? probeRegistry;
  Future<void> Function(List<ProbeResult>)? onProbeResults;
  if (env.immuneProbesEnabled) {
    // Read via Env (dotEnv-backed), not Platform.environment directly, so a
    // value set only in `.env` registers the calendar probe. (dotEnv reads both
    // `.env` and platform env; the reverse is not true.)
    final calendarExpect = env.immuneCalendarExpect;
    // Capture into a local final so null-promotion works inside the closure and
    // the "disabled" (null) signal is preserved distinctly from "returned 0".
    final mr = memoryRetriever;
    final probes = <Probe>[
      AuthProbe(
        readAuthModeLabel: () => alerter.authModeLabel,
        maintenanceMode: maintenanceMode,
      ),
      DeepSearchProbe(executeTool: toolRegistry.executeTool),
      // Opt-in: only when an operator has pinned the expected recurring event,
      // so a wrong guess can't produce a false `failed`.
      if (calendarRetriever != null &&
          calendarExpect != null &&
          calendarExpect.isNotEmpty)
        CalendarProbe(
          fetchUpcoming: calendarRetriever.fetchUpcoming,
          expectedSummarySubstring: calendarExpect,
        ),
      RagProbe(
        retrieveCount: mr == null
            ? null
            : () async =>
                (await mr.retrieve('Imagineering', 'immune-probe')).length,
      ),
    ];

    // Content-integrity antibody (PR2b): catches content-hollow/forgery a wiring
    // probe misses, by retrieving a forge-proof golden through the REAL memory
    // path and verifying its HMAC seal + identity. Requires IMMUNE_SENTINEL_KEY
    // (no key ⇒ no sealer ⇒ no trustworthy check). Seeding is boot infra, not a
    // probe, so it lives here (outside the detect-only registry).
    // Trim once at admission so the guard and the sealer agree on THE key: an
    // env value with accidental surrounding whitespace (`" abc "`) must produce
    // the same HMAC key as `"abc"`, or a later clean re-set silently breaks every
    // seal. Whitespace-only ⇒ null ⇒ treated as unset.
    final rawKey = env.immuneSentinelKey?.trim();
    final sentinelKey = (rawKey != null && rawKey.isNotEmpty) ? rawKey : null;
    if (sentinelKey != null) {
      final sealer = SentinelSealer(sentinelKey);
      final store = FixtureSentinelStore.sealed(sealer, immuneGoldens);
      SealedFetcher? fetch;
      // Gate the fetcher on embeddings: with Voyage off, retrieval returns
      // nothing → the probe would `failed` (false page). Instead leave the
      // fetcher null so the probe reports `degraded` (a known-off capability).
      if (mr != null && voyageClient != null) {
        // Fail OPEN: the golden seed is a paid Voyage call, and the concrete
        // client throws on a non-200 (rate-limit / 5xx). This is diagnostic
        // infra — a dependency brownout must NOT abort River's boot. On any
        // failure, log and leave the fetcher null so the probe reports
        // `degraded`, never euthanising the organism it exists to protect.
        try {
          await GoldenSeeder(
            client: voyageClient,
            queries: queries,
            sealer: sealer,
          ).seed(immuneGoldens);
          fetch = buildGoldenFetcher(retriever: mr);
        } on Object catch (e) {
          log.warning(
            'Golden seed failed; content-integrity probe degraded (not paging)',
            extra: {'error': e.toString()},
          );
        }
      }
      probes.add(
        ContentIntegrityProbe(
          id: 'probe_content_integrity',
          sentinelId: immuneContentGolden.id,
          store: store,
          sealer: sealer,
          fetchSealed: fetch,
        ),
      );
      log.info(
        fetch == null
            ? 'Content-integrity probe registered (degraded: no live fetcher)'
            : 'Content-integrity probe registered + golden seeded',
      );
    } else {
      log.info('Content-integrity probe disabled (no IMMUNE_SENTINEL_KEY)');
    }

    final registry = ProbeRegistry(probes);
    probeRegistry = registry;
    onProbeResults = (results) async {
      for (final r in results) {
        health.recordProbeResult(r);
        if (r.shouldPage) {
          unawaited(
            alerter.escalate(kind: r.id, message: r.detail ?? 'probe failed'),
          );
        }
      }
      // PR2b: surface (never page) antibodies whose recalibration deadline has
      // passed. Runs on both the boot smoke run and every scheduler tick (both
      // call this closure). Paging expired antibodies is PR2c.
      health.recordExpired(registry.expired(DateTime.now().toUtc()));
    };
    // Boot smoke run — also serves the post-deploy smoke-test intent (a
    // silently-broken tool is caught at deploy, not weeks later).
    final bootResults = await probeRegistry.runAll();
    await onProbeResults(bootResults);
    // Write the same dedup key the scheduler uses, so the first tick after
    // startup doesn't immediately re-run and re-page the boot results.
    queries.setMetadata(
      'immune_probe_last',
      DateTime.now().toUtc().toIso8601String(),
    );
    log.info('Immune probes ran at boot', extra: {'count': bootResults.length});
  }

  final scheduler = Scheduler(
    queries: queries,
    sendMessage: sendToRoom,
    probeRegistry: probeRegistry,
    onProbeResults: onProbeResults,
    immuneProbesEnabled: env.immuneProbesEnabled,
    backfill: embeddingBackfill,
    consolidator: memoryConsolidator,
    triggerDream: dreamCycle.trigger,
    eventReminderRoomId: env.eventReminderRoomId,
    communitySparkReviewRoomId: env.communitySparkReviewRoomId,
    communitySparkHubRoomId: env.communitySparkRoomId,
    communitySparkMode: env.communitySparkMode,
    composeViaAgent: (groupId, taskDescription) async {
      final input = AgentInput(
        text: taskDescription,
        chatId: groupId,
        senderId: 'system',
        isAdmin: true,
        isSystemInitiated: true,
      );
      final id = queries.getBotIdentity();
      return agentLoop.processMessage(
        input,
        systemPrompt: buildSystemPrompt(
          input,
          botName: env.botName,
          identity: id,
          personalityTraits:
              id != null ? queries.getPersonalityTraits(id.id) : const [],
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
          ? await memoryRetriever.retrieve(taskDescription, groupId).timeout(
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
        final id = queries.getBotIdentity();
        return agentLoop.processMessage(
          input,
          systemPrompt: buildSystemPrompt(
            input,
            botName: env.botName,
            identity: id,
            personalityTraits:
                id != null ? queries.getPersonalityTraits(id.id) : const [],
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
        // Drop River's own messages — including echoes the superbridge relays
        // back into the hub as relay/bridge puppets (whose MXIDs differ from
        // the native bot MXID). Without the puppet check, River's continuation
        // logic would respond to its own echo, creating a feedback loop.
        if (env.isSelf(event.sender, botUserId)) {
          health.recordMessageDropped('own_message');
          continue;
        }
        if (ignoreRooms.contains(event.roomId)) {
          health.recordMessageDropped('ignored_room');
          continue;
        }
        // Backfill this room's member count before any DM-vs-group decision.
        // A room joined before this process's sync window has no cached
        // summary, so a 2-person DM would otherwise be misclassified as a
        // group and wrongly require a mention to get a reply.
        await matrixClient.ensureMemberCount(event.roomId);

        // Welcome new members joining a group room.
        if (event.isMemberJoin && !matrixClient.isDm(event.roomId)) {
          final displayName = event.memberDisplayName ??
              event.sender.split(':').first.substring(1);
          log.info('New member joined', extra: {
            'room': event.roomId,
            'user': event.sender,
            'name': displayName,
          });

          try {
            await matrixClient.sendMessage(
              roomId: event.roomId,
              message: 'Welcome $displayName! '
                  "Say 'kickstart' here and I'll walk us through setup. ✨",
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

        // Community Spark approval — deterministic and LLM-free. Checked BEFORE
        // the group mention-filter and rate limiter: the private review room is
        // an ordinary Matrix group, so an admin's bare "send" (no @mention)
        // would otherwise be dropped as "not_mentioned" and the gated path
        // would never fire. Publishing the one pending draft is the whole point
        // of the gate, so it must sit ahead of any filter that could drop it.
        if (await scheduler.maybeHandleSparkApproval(
          roomId: event.roomId,
          isAdmin: env.isAdmin(event.sender),
          text: text,
          now: DateTime.now(),
        )) {
          continue;
        }

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
          // Onboarding runs in the group room itself: workspace/roster/projects/
          // knowledge are inherently team-shared, and Meet & Greet becomes a
          // round-the-room intro. Bridged platforms carry per-user identity via
          // puppet MXIDs, so state keyed by sender works in public just fine.
          if (isGroup &&
              isKickstartMessage(text) &&
              !kickstartState.isKickstartActive(event.roomId)) {
            kickstartState.startKickstart(event.roomId);
            log.info('Kickstart started (in-room flow)', extra: {
              'room': event.roomId,
              'sender': event.sender,
            });
            // Don't `continue` — let the agent loop run with the kickstart
            // system prompt injected below, so the first response opens the
            // workspace step right here in the group.
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

          // River can reply with [skip] to deliberately stay quiet.
          final skipped = response.trim() == '[skip]';
          if (skipped) {
            log.info('Chose to stay quiet', extra: {
              'room': event.roomId,
            });
            health.recordMessageDropped('bot_skipped');
          }
          if (response.isNotEmpty && !skipped) {
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
          log.error('Error processing message: $e', extra: {
            'room': event.roomId,
            'stackTrace': '$st',
          });

          // A ClaudeCallFailure means the resilient wrapper already recorded
          // brain health for this; anything else is an unrelated processing
          // error (Matrix send, corrupt history, …) that we count generically.
          if (e is ClaudeCallFailure) {
            // billing/auth here are unrecoverable capability failures — auth
            // means the API-key fallback also failed (or wasn't available);
            // billing means we hit the credit wall, the exact silent-death
            // scenario this PR exists to prevent. Escalate loudly. (`other` is
            // left to the health counter — it's often a one-off bad request,
            // not a sustained outage.)
            if (e.kind == ClaudeErrorKind.billing ||
                e.kind == ClaudeErrorKind.auth) {
              unawaited(
                alerter.escalate(
                    kind: e.kind.name, message: _shortError(e.cause)),
              );
            }
          } else {
            health.recordError();
          }

          // Self-heal: clear corrupt conversation history.
          if (e.toString().contains('tool_use_id') ||
              e.toString().contains('tool_result')) {
            log.warning('Clearing corrupt history', extra: {
              'room': event.roomId,
            });
            history.clearHistory(event.roomId);
            messageRepo.deleteConversation(event.roomId);
          }

          // In-character AND informative in every case (Nick's ask): a
          // Claude failure gets River's kind-aware line + the technical cause;
          // any other processing error names itself as plumbing, not brain.
          // Redact secret-looking substrings before the cause is shown in a
          // room — error text can carry tokens/keys/auth headers (cage-match
          // finding). The kind message stays informative; the raw cause is
          // masked, not dumped.
          final userMessage = e is ClaudeCallFailure
              ? '${claudeErrorUserMessage(e.kind)}\n\n(what broke: ${redactSecrets(_shortError(e.cause))})'
              : 'That broke on my end, not my brain — my plumbing, not my '
                  'thinking. (what broke: ${redactSecrets(_shortError(e))}) Give it another go.';
          try {
            await matrixClient.sendMessage(
              roomId: event.roomId,
              message: userMessage,
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
        milliseconds:
            min(backoff.inMilliseconds * 2, _maxBackoff.inMilliseconds),
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
/// Trims an error's string form to a compact, single-line summary suitable for
/// health JSON and alert bodies (full stack/JSON goes to the logs).
String _shortError(Object e) {
  final s = e.toString().replaceAll('\n', ' ').trim();
  return s.length > 200 ? '${s.substring(0, 200)}…' : s;
}

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
  final personalityTraits = identity != null
      ? queries.getPersonalityTraits(identity.id)
      : const <PersonalityTrait>[];
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

  // Kickstart prompt injection — group-only (kickstart runs in-room).
  if (isGroup) {
    final kickstartStep = kickstartState.getActiveKickstart(chatId);
    if (kickstartStep != null) {
      prompt += buildKickstartPromptSection(kickstartStep, chatId);
    }
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
      SessionPhase.build2 => '⏱️ Back to it! Build 2 starting — 25 minutes.',
      SessionPhase.chat2 =>
        '⏱️ Build 2 done! Check-in time — what\'s working, what\'s not?',
      SessionPhase.build3 =>
        '⏱️ Final build! 25 minutes — polish, test, prep your demo.',
      SessionPhase.chat3 => '⏱️ Build 3 complete! Last check-in before demos. '
          'How did it go? What are you showing?',
      SessionPhase.demo => '🎪 Demo time! Who wants to go first?',
    };
