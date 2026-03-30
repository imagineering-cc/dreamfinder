import 'package:dotenv/dotenv.dart';

/// Application configuration loaded from environment variables and `.env` file.
class Env {
  Env._({
    this.anthropicApiKey,
    this.claudeRefreshToken,
    required this.matrixHomeserver,
    this.matrixAccessToken,
    this.matrixUsername,
    this.matrixPassword,
    this.matrixIgnoreRooms = const [],
    this.kanBaseUrl,
    this.kanApiKey,
    this.outlineBaseUrl,
    this.outlineApiKey,
    this.radicaleBaseUrl,
    this.radicaleUsername,
    this.radicalePassword,
    this.calendarUrl,
    this.eventTimeZone,
    this.adminIds = const [],
    this.botName = 'Dreamfinder',
    this.databasePath = './data/bot.db',
    this.logLevel = 'info',
    this.healthPort = 8081,
    this.apiKey,
    this.deployAnnounceGroupId,
    this.voyageApiKey,
    this.githubToken,
    this.githubRepo,
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
      matrixHomeserver: matrixHomeserver,
      matrixAccessToken: matrixAccessToken,
      matrixUsername: matrixUsername,
      matrixPassword: matrixPassword,
      matrixIgnoreRooms: _parseList(dotEnv['MATRIX_IGNORE_ROOMS']),
      kanBaseUrl: dotEnv['KAN_BASE_URL'],
      kanApiKey: dotEnv['KAN_API_KEY'],
      outlineBaseUrl: dotEnv['OUTLINE_BASE_URL'],
      outlineApiKey: dotEnv['OUTLINE_API_KEY'],
      radicaleBaseUrl: dotEnv['RADICALE_BASE_URL'],
      radicaleUsername: dotEnv['RADICALE_USERNAME'],
      radicalePassword: dotEnv['RADICALE_PASSWORD'],
      calendarUrl: dotEnv['CALENDAR_URL'],
      eventTimeZone: dotEnv['EVENT_TIMEZONE'],
      adminIds: _parseList(dotEnv['ADMIN_IDS'] ?? dotEnv['ADMIN_UUIDS']),
      botName: dotEnv['BOT_NAME'] ?? 'Dreamfinder',
      databasePath: dotEnv['DATABASE_PATH'] ?? './data/bot.db',
      logLevel: dotEnv['LOG_LEVEL'] ?? 'info',
      healthPort: int.tryParse(dotEnv['HEALTH_PORT'] ?? '') ?? 8081,
      apiKey: dotEnv['API_KEY'],
      deployAnnounceGroupId: dotEnv['DEPLOY_ANNOUNCE_GROUP_ID'],
      voyageApiKey: dotEnv['VOYAGE_API_KEY'],
      githubToken: dotEnv['GITHUB_TOKEN'],
      githubRepo: dotEnv['GITHUB_REPO'],
    );
  }

  factory Env.forTesting({
    String? anthropicApiKey = 'test-key',
    String? claudeRefreshToken,
    String matrixHomeserver = 'https://matrix.test',
    String? matrixAccessToken = 'test-token',
    String? matrixUsername,
    String? matrixPassword,
    List<String> matrixIgnoreRooms = const [],
    String? kanBaseUrl,
    String? kanApiKey,
    String? outlineBaseUrl,
    String? outlineApiKey,
    String? radicaleBaseUrl,
    String? radicaleUsername,
    String? radicalePassword,
    String? calendarUrl,
    String? eventTimeZone,
    List<String> adminIds = const [],
    String botName = 'Dreamfinder',
    String databasePath = './data/bot.db',
    String logLevel = 'info',
    int healthPort = 8081,
    String? apiKey,
    String? deployAnnounceGroupId,
    String? voyageApiKey,
    String? githubToken,
    String? githubRepo,
  }) =>
      Env._(
        anthropicApiKey: anthropicApiKey,
        claudeRefreshToken: claudeRefreshToken,
        matrixHomeserver: matrixHomeserver,
        matrixAccessToken: matrixAccessToken,
        matrixUsername: matrixUsername,
        matrixPassword: matrixPassword,
        matrixIgnoreRooms: matrixIgnoreRooms,
        kanBaseUrl: kanBaseUrl,
        kanApiKey: kanApiKey,
        outlineBaseUrl: outlineBaseUrl,
        outlineApiKey: outlineApiKey,
        radicaleBaseUrl: radicaleBaseUrl,
        radicaleUsername: radicaleUsername,
        radicalePassword: radicalePassword,
        calendarUrl: calendarUrl,
        eventTimeZone: eventTimeZone,
        adminIds: adminIds,
        botName: botName,
        databasePath: databasePath,
        logLevel: logLevel,
        healthPort: healthPort,
        apiKey: apiKey,
        deployAnnounceGroupId: deployAnnounceGroupId,
        voyageApiKey: voyageApiKey,
        githubToken: githubToken,
        githubRepo: githubRepo,
      );

  /// Anthropic API key. Null when using OAuth auth.
  final String? anthropicApiKey;

  /// Claude Max OAuth refresh token. If set, used instead of [anthropicApiKey].
  final String? claudeRefreshToken;

  /// Whether OAuth auth is configured (vs API key auth).
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

  /// User IDs that have admin privileges (from `ADMIN_IDS` env var,
  /// falls back to `ADMIN_UUIDS` for backward compatibility).
  final List<String> adminIds;

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

  /// Voyage AI API key for generating text embeddings.
  /// If null, the RAG memory system is disabled.
  final String? voyageApiKey;

  /// GitHub fine-grained PAT for reading repo contents and managing issues.
  /// If null, GitHub tools are disabled.
  final String? githubToken;

  /// Default GitHub repository in `owner/name` format (from `GITHUB_REPO`).
  /// Defaults to `imagineering-cc/dreamfinder` if not set.
  final String? githubRepo;

  /// Returns `true` if [userId] is in the configured admin list.
  bool isAdmin(String? userId) =>
      userId != null && adminIds.contains(userId);

  bool get kanEnabled => kanApiKey != null && kanApiKey!.isNotEmpty;
  bool get outlineEnabled => outlineApiKey != null && outlineApiKey!.isNotEmpty;
  bool get radicaleEnabled =>
      radicalePassword != null && radicalePassword!.isNotEmpty;
  bool get voyageEnabled => voyageApiKey != null && voyageApiKey!.isNotEmpty;
  bool get githubEnabled => githubToken != null && githubToken!.isNotEmpty;

  /// Parses a comma-separated string into a trimmed list.
  static List<String> _parseList(String? value) {
    if (value == null || value.isEmpty) return const [];
    return value.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
  }
}
