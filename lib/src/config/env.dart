import 'dart:io';

import 'package:dotenv/dotenv.dart';

/// Default per-user cooldown in seconds.
const _defaultRateLimitPerUserSeconds = 5;

/// Default maximum bot responses per group window.
const _defaultRateLimitGroupMax = 5;

/// Default group rate-limit window in seconds.
const _defaultRateLimitGroupWindowSeconds = 30;

/// Application configuration loaded from environment variables and `.env` file.
class Env {
  Env._({
    this.anthropicApiKey,
    this.claudeRefreshToken,
    this.claudeCodeOAuthToken,
    required this.matrixHomeserver,
    this.matrixAccessToken,
    this.matrixUsername,
    this.matrixPassword,
    this.matrixIgnoreRooms = const [],
    this.matrixAlwaysRespondRooms = const [],
    this.bridgeBotIds = const [],
    this.whatsappManagementRoom,
    this.telegramManagementRoom,
    this.signalManagementRoom,
    this.discordManagementRoom,
    this.kanBaseUrl,
    this.kanApiKey,
    this.kanWorkspaceId,
    this.outlineBaseUrl,
    this.outlineApiKey,
    this.radicaleBaseUrl,
    this.radicaleUsername,
    this.radicalePassword,
    this.calendarUrl,
    this.eventTimeZone,
    this.adminIds = const [],
    this.selfPuppetIds = const [],
    this.botName = 'Dreamfinder',
    this.databasePath = './data/bot.db',
    this.logLevel = 'info',
    this.healthPort = 8081,
    this.apiKey,
    this.deployAnnounceGroupId,
    this.eventReminderRoomId,
    this.communitySparkRoomId,
    this.communitySparkReviewRoomId,
    this.communitySparkMode = 'gated',
    this.voyageApiKey,
    this.githubToken,
    this.githubRepo,
    this.liveKitUrl,
    this.liveKitApiKey,
    this.liveKitApiSecret,
    this.notifyUrl,
    this.notifyApiKey,
    this.rateLimitPerUserSeconds = _defaultRateLimitPerUserSeconds,
    this.rateLimitGroupMax = _defaultRateLimitGroupMax,
    this.rateLimitGroupWindowSeconds = _defaultRateLimitGroupWindowSeconds,
    this.maintenanceMode = 'none',
    this.immuneProbesEnabled = false,
    this.immuneCalendarExpect,
    this.immuneSentinelKey,
  });

  factory Env.load() {
    final dotEnv = DotEnv(includePlatformEnvironment: true)..load();
    final anthropicApiKey = dotEnv['ANTHROPIC_API_KEY'];
    final claudeRefreshToken = dotEnv['CLAUDE_REFRESH_TOKEN'];
    final claudeCodeOAuthToken = dotEnv['CLAUDE_CODE_OAUTH_TOKEN'];
    if ((anthropicApiKey == null || anthropicApiKey.isEmpty) &&
        (claudeRefreshToken == null || claudeRefreshToken.isEmpty) &&
        (claudeCodeOAuthToken == null || claudeCodeOAuthToken.isEmpty)) {
      throw StateError(
        'One of ANTHROPIC_API_KEY, CLAUDE_CODE_OAUTH_TOKEN, or '
        'CLAUDE_REFRESH_TOKEN is required',
      );
    }
    final matrixHomeserver = dotEnv['MATRIX_HOMESERVER'];
    if (matrixHomeserver == null || matrixHomeserver.isEmpty) {
      throw StateError('MATRIX_HOMESERVER is required');
    }
    final matrixAccessToken = dotEnv['MATRIX_ACCESS_TOKEN'];
    final matrixUsername = dotEnv['MATRIX_USERNAME'];
    final matrixPassword = dotEnv['MATRIX_PASSWORD'];
    if ((matrixAccessToken == null || matrixAccessToken.isEmpty) &&
        (matrixUsername == null || matrixUsername.isEmpty)) {
      throw StateError(
        'Either MATRIX_ACCESS_TOKEN or MATRIX_USERNAME + MATRIX_PASSWORD '
        'is required',
      );
    }
    return Env._(
      anthropicApiKey: anthropicApiKey,
      claudeRefreshToken: claudeRefreshToken,
      claudeCodeOAuthToken: claudeCodeOAuthToken,
      matrixHomeserver: matrixHomeserver,
      matrixAccessToken: matrixAccessToken,
      matrixUsername: matrixUsername,
      matrixPassword: matrixPassword,
      matrixIgnoreRooms: _parseList(dotEnv['MATRIX_IGNORE_ROOMS']),
      matrixAlwaysRespondRooms:
          _parseList(dotEnv['MATRIX_ALWAYS_RESPOND_ROOMS']),
      bridgeBotIds: _parseList(dotEnv['BRIDGE_BOT_IDS']),
      whatsappManagementRoom: dotEnv['WHATSAPP_MANAGEMENT_ROOM'],
      telegramManagementRoom: dotEnv['TELEGRAM_MANAGEMENT_ROOM'],
      signalManagementRoom: dotEnv['SIGNAL_MANAGEMENT_ROOM'],
      discordManagementRoom: dotEnv['DISCORD_MANAGEMENT_ROOM'],
      kanBaseUrl: dotEnv['KAN_BASE_URL'],
      kanApiKey: dotEnv['KAN_API_KEY'],
      kanWorkspaceId: dotEnv['KAN_WORKSPACE_ID'],
      outlineBaseUrl: dotEnv['OUTLINE_BASE_URL'],
      outlineApiKey: dotEnv['OUTLINE_API_KEY'],
      radicaleBaseUrl: dotEnv['RADICALE_BASE_URL'],
      radicaleUsername: dotEnv['RADICALE_USERNAME'],
      radicalePassword: dotEnv['RADICALE_PASSWORD'],
      calendarUrl: dotEnv['CALENDAR_URL'],
      eventTimeZone: dotEnv['EVENT_TIMEZONE'],
      adminIds: _parseList(dotEnv['ADMIN_IDS'] ?? dotEnv['ADMIN_UUIDS']),
      selfPuppetIds: _parseList(dotEnv['SELF_PUPPET_IDS']),
      botName: dotEnv['BOT_NAME'] ?? 'Dreamfinder',
      databasePath: dotEnv['DATABASE_PATH'] ?? './data/bot.db',
      logLevel: dotEnv['LOG_LEVEL'] ?? 'info',
      healthPort: int.tryParse(dotEnv['HEALTH_PORT'] ?? '') ?? 8081,
      apiKey: dotEnv['API_KEY'],
      deployAnnounceGroupId: dotEnv['DEPLOY_ANNOUNCE_GROUP_ID'],
      eventReminderRoomId: dotEnv['EVENT_REMINDER_ROOM_ID'],
      communitySparkRoomId: dotEnv['COMMUNITY_SPARK_ROOM_ID'],
      communitySparkReviewRoomId: dotEnv['COMMUNITY_SPARK_REVIEW_ROOM_ID'],
      communitySparkMode: dotEnv['COMMUNITY_SPARK_MODE'] ?? 'gated',
      voyageApiKey: dotEnv['VOYAGE_API_KEY'],
      githubToken: dotEnv['GITHUB_TOKEN'],
      githubRepo: dotEnv['GITHUB_REPO'],
      liveKitUrl: dotEnv['LIVEKIT_URL'],
      liveKitApiKey: dotEnv['LIVEKIT_API_KEY'],
      liveKitApiSecret: dotEnv['LIVEKIT_API_SECRET'],
      notifyUrl: dotEnv['NOTIFY_URL'],
      notifyApiKey: dotEnv['NOTIFY_API_KEY'],
      rateLimitPerUserSeconds: _parsePositiveInt(
        dotEnv['RATE_LIMIT_PER_USER_SECONDS'],
        'RATE_LIMIT_PER_USER_SECONDS',
        _defaultRateLimitPerUserSeconds,
      ),
      rateLimitGroupMax: _parsePositiveInt(
        dotEnv['RATE_LIMIT_GROUP_MAX'],
        'RATE_LIMIT_GROUP_MAX',
        _defaultRateLimitGroupMax,
      ),
      rateLimitGroupWindowSeconds: _parsePositiveInt(
        dotEnv['RATE_LIMIT_GROUP_WINDOW_SECONDS'],
        'RATE_LIMIT_GROUP_WINDOW_SECONDS',
        _defaultRateLimitGroupWindowSeconds,
      ),
      maintenanceMode: dotEnv['MAINTENANCE_MODE'] ?? 'none',
      immuneProbesEnabled:
          (dotEnv['IMMUNE_PROBES_ENABLED'] ?? '').toLowerCase() == 'true',
      immuneCalendarExpect: dotEnv['IMMUNE_CALENDAR_EXPECT'],
      immuneSentinelKey: dotEnv['IMMUNE_SENTINEL_KEY'],
    );
  }

  factory Env.forTesting({
    String? anthropicApiKey = 'test-key',
    String? claudeRefreshToken,
    String? claudeCodeOAuthToken,
    String matrixHomeserver = 'https://matrix.test',
    String? matrixAccessToken = 'test-token',
    String? matrixUsername,
    String? matrixPassword,
    List<String> matrixIgnoreRooms = const [],
    List<String> matrixAlwaysRespondRooms = const [],
    List<String> bridgeBotIds = const [],
    String? whatsappManagementRoom,
    String? telegramManagementRoom,
    String? signalManagementRoom,
    String? discordManagementRoom,
    String? kanBaseUrl,
    String? kanApiKey,
    String? kanWorkspaceId,
    String? outlineBaseUrl,
    String? outlineApiKey,
    String? radicaleBaseUrl,
    String? radicaleUsername,
    String? radicalePassword,
    String? calendarUrl,
    String? eventTimeZone,
    List<String> adminIds = const [],
    List<String> selfPuppetIds = const [],
    String botName = 'Dreamfinder',
    String databasePath = './data/bot.db',
    String logLevel = 'info',
    int healthPort = 8081,
    String? apiKey,
    String? deployAnnounceGroupId,
    String? eventReminderRoomId,
    String? communitySparkRoomId,
    String? communitySparkReviewRoomId,
    String communitySparkMode = 'gated',
    String? voyageApiKey,
    String? githubToken,
    String? githubRepo,
    String? liveKitUrl,
    String? liveKitApiKey,
    String? liveKitApiSecret,
    String? notifyUrl,
    String? notifyApiKey,
    int rateLimitPerUserSeconds = _defaultRateLimitPerUserSeconds,
    int rateLimitGroupMax = _defaultRateLimitGroupMax,
    int rateLimitGroupWindowSeconds = _defaultRateLimitGroupWindowSeconds,
    String maintenanceMode = 'none',
    bool immuneProbesEnabled = false,
    String? immuneCalendarExpect,
    String? immuneSentinelKey,
  }) =>
      Env._(
        anthropicApiKey: anthropicApiKey,
        claudeRefreshToken: claudeRefreshToken,
        claudeCodeOAuthToken: claudeCodeOAuthToken,
        matrixHomeserver: matrixHomeserver,
        matrixAccessToken: matrixAccessToken,
        matrixUsername: matrixUsername,
        matrixPassword: matrixPassword,
        matrixIgnoreRooms: matrixIgnoreRooms,
        matrixAlwaysRespondRooms: matrixAlwaysRespondRooms,
        bridgeBotIds: bridgeBotIds,
        whatsappManagementRoom: whatsappManagementRoom,
        telegramManagementRoom: telegramManagementRoom,
        signalManagementRoom: signalManagementRoom,
        discordManagementRoom: discordManagementRoom,
        kanBaseUrl: kanBaseUrl,
        kanApiKey: kanApiKey,
        kanWorkspaceId: kanWorkspaceId,
        outlineBaseUrl: outlineBaseUrl,
        outlineApiKey: outlineApiKey,
        radicaleBaseUrl: radicaleBaseUrl,
        radicaleUsername: radicaleUsername,
        radicalePassword: radicalePassword,
        calendarUrl: calendarUrl,
        eventTimeZone: eventTimeZone,
        adminIds: adminIds,
        selfPuppetIds: selfPuppetIds,
        botName: botName,
        databasePath: databasePath,
        logLevel: logLevel,
        healthPort: healthPort,
        apiKey: apiKey,
        deployAnnounceGroupId: deployAnnounceGroupId,
        eventReminderRoomId: eventReminderRoomId,
        communitySparkRoomId: communitySparkRoomId,
        communitySparkReviewRoomId: communitySparkReviewRoomId,
        communitySparkMode: communitySparkMode,
        voyageApiKey: voyageApiKey,
        githubToken: githubToken,
        githubRepo: githubRepo,
        liveKitUrl: liveKitUrl,
        liveKitApiKey: liveKitApiKey,
        liveKitApiSecret: liveKitApiSecret,
        notifyUrl: notifyUrl,
        notifyApiKey: notifyApiKey,
        rateLimitPerUserSeconds: rateLimitPerUserSeconds,
        rateLimitGroupMax: rateLimitGroupMax,
        rateLimitGroupWindowSeconds: rateLimitGroupWindowSeconds,
        maintenanceMode: maintenanceMode,
        immuneProbesEnabled: immuneProbesEnabled,
        immuneCalendarExpect: immuneCalendarExpect,
        immuneSentinelKey: immuneSentinelKey,
      );

  /// Anthropic API key. Null when using OAuth auth.
  final String? anthropicApiKey;

  /// Claude Max OAuth refresh token. If set, used instead of [anthropicApiKey].
  final String? claudeRefreshToken;

  /// Long-lived Claude Code OAuth token (from `claude setup-token`), used
  /// directly as a `Authorization: Bearer` header — no refresh exchange.
  ///
  /// This is the most robust Claude Max credential: it's valid ~1 year, isn't
  /// single-use, and isn't tied to a rotating interactive-session keychain
  /// lineage, so it sidesteps the refresh-token reuse/poisoning races that
  /// [claudeRefreshToken] is subject to. Takes precedence over both other
  /// modes when set.
  final String? claudeCodeOAuthToken;

  /// Whether the long-lived direct-Bearer OAuth token is configured.
  bool get useDirectBearer =>
      claudeCodeOAuthToken != null && claudeCodeOAuthToken!.isNotEmpty;

  /// Whether refresh-token OAuth auth is configured (vs API key auth).
  bool get useOAuth =>
      claudeRefreshToken != null && claudeRefreshToken!.isNotEmpty;

  /// Matrix homeserver URL (e.g., `https://matrix.imagineering.cc`).
  final String matrixHomeserver;

  /// Matrix access token (preferred for bots). If null, uses
  /// [matrixUsername] + [matrixPassword] to login.
  final String? matrixAccessToken;

  /// Matrix username for password login (alternative to [matrixAccessToken]).
  final String? matrixUsername;

  /// Matrix password for password login.
  final String? matrixPassword;

  /// Room IDs to ignore (from `MATRIX_IGNORE_ROOMS`, comma-separated).
  final List<String> matrixIgnoreRooms;

  /// Room IDs where the bot responds to every message, not just mentions
  /// (from `MATRIX_ALWAYS_RESPOND_ROOMS`, comma-separated).
  final List<String> matrixAlwaysRespondRooms;

  /// Matrix user IDs of bridge appservice bots (from `BRIDGE_BOT_IDS`,
  /// comma-separated, e.g. `@whatsappbot:imagineering.cc`).
  ///
  /// Excluded from DM member counting so bridge portal rooms (which always
  /// contain the bridge bot as an extra member) are correctly detected as
  /// DMs. See `MatrixClient.bridgeBotIds`.
  final List<String> bridgeBotIds;

  /// The bot's WhatsApp-bridge management room (from
  /// `WHATSAPP_MANAGEMENT_ROOM`) — the room shared with the WhatsApp bridge
  /// bot where `start-chat` commands are issued. If null, the WhatsApp
  /// platform is absent from the `start_private_chat` tool.
  final String? whatsappManagementRoom;

  /// The bot's Telegram-bridge management room (from
  /// `TELEGRAM_MANAGEMENT_ROOM`). Same role as [whatsappManagementRoom] but
  /// for the mautrix-telegram bridge; null disables the Telegram platform in
  /// `start_private_chat`.
  final String? telegramManagementRoom;

  /// The bot's Signal-bridge management room (from `SIGNAL_MANAGEMENT_ROOM`).
  /// Null disables the Signal platform in `start_private_chat`.
  final String? signalManagementRoom;

  /// The bot's Discord-bridge management room (from
  /// `DISCORD_MANAGEMENT_ROOM`). Null disables the Discord platform in
  /// `start_private_chat`.
  final String? discordManagementRoom;

  final String? kanBaseUrl;
  final String? kanApiKey;

  /// Kan workspace public id, required for the `deep_search` Kan arm (the
  /// `kan search` CLI verb needs a workspace). When unset, Kan is reported as
  /// an unavailable deep_search source rather than searched.
  final String? kanWorkspaceId;
  final String? outlineBaseUrl;
  final String? outlineApiKey;
  final String? radicaleBaseUrl;
  final String? radicaleUsername;
  final String? radicalePassword;

  /// Full CalDAV URL to query for upcoming events (e.g.,
  /// `https://dav.example.com/user/calendar/`). If null, calendar event
  /// awareness is disabled.
  final String? calendarUrl;

  /// IANA timezone for displaying event times in the system prompt (e.g.,
  /// `Australia/Melbourne`). If null, times are displayed in UTC.
  final String? eventTimeZone;

  /// User IDs that have admin privileges (from `ADMIN_IDS` env var,
  /// falls back to `ADMIN_UUIDS` for backward compatibility).
  final List<String> adminIds;

  /// Matrix user IDs that are River's OWN bridged/relayed identities (from
  /// `SELF_PUPPET_IDS`). When River posts to the hub, the superbridge relays
  /// the message back in as a relay/bridge puppet (e.g. `@_relay_signal_…`,
  /// `@telegram_…`) whose MXID differs from the native bot MXID — so the
  /// `event.sender == botUserId` self-check misses it and River would respond
  /// to its own echo (a feedback loop). These IDs are treated as "self" and
  /// dropped. See [isSelf].
  final List<String> selfPuppetIds;

  final String botName;
  final String databasePath;
  final String logLevel;

  /// Port for the health check HTTP endpoint (from `HEALTH_PORT` env var).
  final int healthPort;

  /// Shared API key for authenticating requests to the memory API endpoints.
  /// If null, memory API endpoints are disabled (health check still works).
  final String? apiKey;

  /// Group/room ID to send deploy announcements to.
  /// If null, deploy announcements are disabled.
  final String? deployAnnounceGroupId;

  /// Matrix room ID of the Imagineering group (a mautrix-telegram portal room)
  /// to send the weekly "session starts in 5 minutes" reminder to.
  /// If null, the event reminder is disabled. See [Scheduler].
  final String? eventReminderRoomId;

  /// Public hub room (a bridged portal) Community Spark publishes to once a
  /// draft is approved, and the context River composes the spark in. If null,
  /// the spark has nowhere to publish. From `COMMUNITY_SPARK_ROOM_ID`.
  final String? communitySparkRoomId;

  /// Private review room (River + admins, NOT bridged) where Community Spark
  /// drafts await human approval. If null, Community Spark is disabled. From
  /// `COMMUNITY_SPARK_REVIEW_ROOM_ID`.
  final String? communitySparkReviewRoomId;

  /// Community Spark mode: `gated` (draft → approval → publish) or `autonomous`.
  /// Defaults to `gated`. From `COMMUNITY_SPARK_MODE`.
  final String communitySparkMode;

  /// Voyage AI API key for generating text embeddings.
  /// If null, the RAG memory system is disabled.
  final String? voyageApiKey;

  /// GitHub fine-grained PAT for reading repo contents and managing issues.
  /// If null, GitHub tools are disabled.
  final String? githubToken;

  /// Default GitHub repository in `owner/name` format (from `GITHUB_REPO`).
  /// Defaults to `imagineering-cc/dreamfinder` if not set.
  final String? githubRepo;

  /// LiveKit server URL for the game bridge (e.g., `wss://lk.example.com`).
  final String? liveKitUrl;

  /// LiveKit API key for server-side data channel access.
  final String? liveKitApiKey;

  /// LiveKit API secret for HS256 JWT signing.
  final String? liveKitApiSecret;

  /// Base URL of the `notify` sidecar used to escalate brain failures to
  /// Telegram (e.g. `http://host.docker.internal:8090`). If null, the Telegram
  /// escalation channel is disabled.
  final String? notifyUrl;

  /// Bearer token for the `notify` sidecar. If null, the Telegram escalation
  /// channel is disabled.
  final String? notifyApiKey;

  /// Per-user cooldown in seconds (from `RATE_LIMIT_PER_USER_SECONDS`).
  ///
  /// Minimum time the bot waits before responding to the same user again.
  /// Default: 5. Non-positive values fall back to the default with a warning.
  final int rateLimitPerUserSeconds;

  /// Maximum bot responses per group within [rateLimitGroupWindowSeconds]
  /// (from `RATE_LIMIT_GROUP_MAX`).
  ///
  /// Raise this for demos with many concurrent users (e.g., 20).
  /// Default: 5. Non-positive values fall back to the default with a warning.
  final int rateLimitGroupMax;

  /// Group rate-limit window in seconds (from `RATE_LIMIT_GROUP_WINDOW_SECONDS`).
  ///
  /// The rolling window over which [rateLimitGroupMax] responses are counted.
  /// Default: 30. Non-positive values fall back to the default with a warning.
  final int rateLimitGroupWindowSeconds;

  /// Returns `true` if [userId] is in the configured admin list.
  bool isAdmin(String? userId) => userId != null && adminIds.contains(userId);

  /// Whether [userId] is one of River's own identities — either the native bot
  /// MXID ([botUserId]) or one of its relayed/bridged puppets ([selfPuppetIds]).
  /// Used to drop self-echoes the superbridge relays back into the hub, which
  /// would otherwise create a response feedback loop.
  bool isSelf(String? userId, String botUserId) =>
      userId == botUserId || (userId != null && selfPuppetIds.contains(userId));

  bool get kanEnabled => kanApiKey != null && kanApiKey!.isNotEmpty;
  bool get outlineEnabled => outlineApiKey != null && outlineApiKey!.isNotEmpty;
  bool get radicaleEnabled =>
      radicalePassword != null && radicalePassword!.isNotEmpty;
  bool get voyageEnabled => voyageApiKey != null && voyageApiKey!.isNotEmpty;
  bool get githubEnabled => githubToken != null && githubToken!.isNotEmpty;
  bool get liveKitEnabled =>
      liveKitUrl != null && liveKitApiKey != null && liveKitApiSecret != null;

  /// Operator maintenance mode (`MAINTENANCE_MODE`). Raw string; convert with
  /// `MaintenanceMode.fromEnv` at the boot-check call site so this config layer
  /// stays free of any `immune/` dependency. Default `'none'`.
  final String maintenanceMode;

  /// Whether the immune-system probe tick runs (`IMMUNE_PROBES_ENABLED`).
  /// Ships false — enabled only after the positive/negative backtest passes.
  final bool immuneProbesEnabled;

  /// Expected recurring-event summary substring for the calendar probe
  /// (`IMMUNE_CALENDAR_EXPECT`). Null/unset → the calendar probe stays
  /// unregistered (a wrong guess can't produce a false `failed`). Routed
  /// through here (not `Platform.environment` directly) so a value set only in
  /// `.env` is honoured — `DotEnv(includePlatformEnvironment: true)` reads both,
  /// but a `.env` value never lands in `Platform.environment`.
  final String? immuneCalendarExpect;

  /// Secret HMAC key for the immune system's forge-proof content sentinels
  /// (`IMMUNE_SENTINEL_KEY`). Null/unset → the content-integrity probe stays
  /// unregistered (no key ⇒ no sealer ⇒ no trustworthy content check). Never
  /// stored in a user-writable store; only the immune system holds it, so a
  /// planted look-alike record in the corpus cannot produce a valid seal.
  final String? immuneSentinelKey;

  /// Parses an integer env var, falling back to [defaultValue] if unset or
  /// non-positive, writing a warning to stderr on invalid/non-positive input.
  static int _parsePositiveInt(
    String? raw,
    String varName,
    int defaultValue,
  ) {
    if (raw == null || raw.isEmpty) return defaultValue;
    final parsed = int.tryParse(raw);
    if (parsed == null) {
      stderr.writeln(
        'WARNING: $varName has non-integer value "$raw"; '
        'using default $defaultValue',
      );
      return defaultValue;
    }
    if (parsed <= 0) {
      stderr.writeln(
        'WARNING: $varName must be positive (got $parsed); '
        'using default $defaultValue',
      );
      return defaultValue;
    }
    return parsed;
  }

  /// Parses a comma-separated string into a trimmed list.
  static List<String> _parseList(String? value) {
    if (value == null || value.isEmpty) return const [];
    return value
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }
}
