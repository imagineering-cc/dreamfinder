import 'package:dotenv/dotenv.dart';

/// Application configuration loaded from environment variables and `.env` file.
class Env {
  Env._({
    this.anthropicApiKey,
    required this.signalApiUrl,
    required this.signalPhoneNumber,
    this.claudeRefreshToken,
    this.kanBaseUrl,
    this.kanApiKey,
    this.outlineBaseUrl,
    this.outlineApiKey,
    this.radicaleBaseUrl,
    this.radicaleUsername,
    this.radicalePassword,
    this.calendarUrl,
    this.eventTimeZone,
    this.adminUuids = const [],
    this.kanMcpPath,
    this.botName = 'Dreamfinder',
    this.databasePath = './data/bot.db',
    this.logLevel = 'info',
    this.healthPort = 8081,
    this.deployAnnounceGroupId,
    this.voyageApiKey,
  });

  factory Env.load() {
    final dotEnv = DotEnv(includePlatformEnvironment: true)..load();
    final anthropicApiKey = dotEnv['ANTHROPIC_API_KEY'];
    final claudeRefreshToken = dotEnv['CLAUDE_REFRESH_TOKEN'];
    if ((anthropicApiKey == null || anthropicApiKey.isEmpty) &&
        (claudeRefreshToken == null || claudeRefreshToken.isEmpty)) {
      throw StateError(
        'Either ANTHROPIC_API_KEY or CLAUDE_REFRESH_TOKEN is required',
      );
    }
    final signalApiUrl = dotEnv['SIGNAL_API_URL'];
    if (signalApiUrl == null || signalApiUrl.isEmpty) {
      throw StateError('SIGNAL_API_URL is required');
    }
    final signalPhoneNumber = dotEnv['SIGNAL_PHONE_NUMBER'];
    if (signalPhoneNumber == null || signalPhoneNumber.isEmpty) {
      throw StateError('SIGNAL_PHONE_NUMBER is required');
    }
    return Env._(
      anthropicApiKey: anthropicApiKey,
      claudeRefreshToken: claudeRefreshToken,
      signalApiUrl: signalApiUrl,
      signalPhoneNumber: signalPhoneNumber,
      kanBaseUrl: dotEnv['KAN_BASE_URL'],
      kanApiKey: dotEnv['KAN_API_KEY'],
      outlineBaseUrl: dotEnv['OUTLINE_BASE_URL'],
      outlineApiKey: dotEnv['OUTLINE_API_KEY'],
      radicaleBaseUrl: dotEnv['RADICALE_BASE_URL'],
      radicaleUsername: dotEnv['RADICALE_USERNAME'],
      radicalePassword: dotEnv['RADICALE_PASSWORD'],
      calendarUrl: dotEnv['CALENDAR_URL'],
      eventTimeZone: dotEnv['EVENT_TIMEZONE'],
      adminUuids: _parseList(dotEnv['ADMIN_UUIDS']),
      kanMcpPath: dotEnv['KAN_MCP_PATH'],
      botName: dotEnv['BOT_NAME'] ?? 'Dreamfinder',
      databasePath: dotEnv['DATABASE_PATH'] ?? './data/bot.db',
      logLevel: dotEnv['LOG_LEVEL'] ?? 'info',
      healthPort: int.tryParse(dotEnv['HEALTH_PORT'] ?? '') ?? 8081,
      deployAnnounceGroupId: dotEnv['DEPLOY_ANNOUNCE_GROUP_ID'],
      voyageApiKey: dotEnv['VOYAGE_API_KEY'],
    );
  }

  factory Env.forTesting({
    String? anthropicApiKey = 'test-key',
    String? claudeRefreshToken,
    String signalApiUrl = 'http://localhost:8080',
    String signalPhoneNumber = '+1234567890',
    String? kanBaseUrl,
    String? kanApiKey,
    String? outlineBaseUrl,
    String? outlineApiKey,
    String? radicaleBaseUrl,
    String? radicaleUsername,
    String? radicalePassword,
    String? calendarUrl,
    String? eventTimeZone,
    List<String> adminUuids = const [],
    String? kanMcpPath,
    String botName = 'Dreamfinder',
    String databasePath = './data/bot.db',
    String logLevel = 'info',
    int healthPort = 8081,
    String? deployAnnounceGroupId,
    String? voyageApiKey,
  }) =>
      Env._(
        anthropicApiKey: anthropicApiKey,
        claudeRefreshToken: claudeRefreshToken,
        signalApiUrl: signalApiUrl,
        signalPhoneNumber: signalPhoneNumber,
        kanBaseUrl: kanBaseUrl,
        kanApiKey: kanApiKey,
        outlineBaseUrl: outlineBaseUrl,
        outlineApiKey: outlineApiKey,
        radicaleBaseUrl: radicaleBaseUrl,
        radicaleUsername: radicaleUsername,
        radicalePassword: radicalePassword,
        calendarUrl: calendarUrl,
        eventTimeZone: eventTimeZone,
        adminUuids: adminUuids,
        kanMcpPath: kanMcpPath,
        botName: botName,
        databasePath: databasePath,
        logLevel: logLevel,
        healthPort: healthPort,
        deployAnnounceGroupId: deployAnnounceGroupId,
        voyageApiKey: voyageApiKey,
      );

  /// Anthropic API key. Null when using OAuth auth.
  final String? anthropicApiKey;

  /// Claude Max OAuth refresh token. If set, used instead of [anthropicApiKey].
  final String? claudeRefreshToken;

  /// Whether OAuth auth is configured (vs API key auth).
  bool get useOAuth =>
      claudeRefreshToken != null && claudeRefreshToken!.isNotEmpty;

  final String signalApiUrl;
  final String signalPhoneNumber;
  final String? kanBaseUrl;
  final String? kanApiKey;
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

  /// Signal UUIDs that have admin privileges (from `ADMIN_UUIDS` env var).
  final List<String> adminUuids;

  /// Path to the Kan MCP server entry point (from `KAN_MCP_PATH` env var).
  final String? kanMcpPath;
  final String botName;
  final String databasePath;
  final String logLevel;

  /// Port for the health check HTTP endpoint (from `HEALTH_PORT` env var).
  final int healthPort;

  /// Signal group ID to send deploy announcements to.
  /// If null, deploy announcements are disabled.
  final String? deployAnnounceGroupId;

  /// Voyage AI API key for generating text embeddings.
  /// If null, the RAG memory system is disabled.
  final String? voyageApiKey;

  /// Returns `true` if [signalUuid] is in the configured admin list.
  bool isAdmin(String? signalUuid) =>
      signalUuid != null && adminUuids.contains(signalUuid);

  bool get kanEnabled => kanApiKey != null && kanApiKey!.isNotEmpty;
  bool get outlineEnabled => outlineApiKey != null && outlineApiKey!.isNotEmpty;
  bool get radicaleEnabled =>
      radicalePassword != null && radicalePassword!.isNotEmpty;
  bool get voyageEnabled => voyageApiKey != null && voyageApiKey!.isNotEmpty;

  /// Parses a comma-separated string into a trimmed list.
  static List<String> _parseList(String? value) {
    if (value == null || value.isEmpty) return const [];
    return value.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
  }
}
