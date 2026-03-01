import 'package:dotenv/dotenv.dart';

/// Application configuration loaded from environment variables and `.env` file.
class Env {
  Env._({
    required this.anthropicApiKey,
    required this.signalApiUrl,
    required this.signalPhoneNumber,
    this.kanBaseUrl,
    this.kanApiKey,
    this.outlineBaseUrl,
    this.outlineApiKey,
    this.radicaleBaseUrl,
    this.radicaleUsername,
    this.radicalePassword,
    this.adminUuids = const [],
    this.kanMcpPath,
    this.botName = 'Dreamfinder',
    this.databasePath = './data/bot.db',
    this.logLevel = 'info',
  });

  factory Env.load() {
    final dotEnv = DotEnv(includePlatformEnvironment: true)..load();
    final anthropicApiKey = dotEnv['ANTHROPIC_API_KEY'];
    if (anthropicApiKey == null || anthropicApiKey.isEmpty) {
      throw StateError('ANTHROPIC_API_KEY is required');
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
      signalApiUrl: signalApiUrl,
      signalPhoneNumber: signalPhoneNumber,
      kanBaseUrl: dotEnv['KAN_BASE_URL'],
      kanApiKey: dotEnv['KAN_API_KEY'],
      outlineBaseUrl: dotEnv['OUTLINE_BASE_URL'],
      outlineApiKey: dotEnv['OUTLINE_API_KEY'],
      radicaleBaseUrl: dotEnv['RADICALE_BASE_URL'],
      radicaleUsername: dotEnv['RADICALE_USERNAME'],
      radicalePassword: dotEnv['RADICALE_PASSWORD'],
      adminUuids: _parseList(dotEnv['ADMIN_UUIDS']),
      kanMcpPath: dotEnv['KAN_MCP_PATH'],
      botName: dotEnv['BOT_NAME'] ?? 'Dreamfinder',
      databasePath: dotEnv['DATABASE_PATH'] ?? './data/bot.db',
      logLevel: dotEnv['LOG_LEVEL'] ?? 'info',
    );
  }

  factory Env.forTesting({
    String anthropicApiKey = 'test-key',
    String signalApiUrl = 'http://localhost:8080',
    String signalPhoneNumber = '+1234567890',
    String? kanBaseUrl,
    String? kanApiKey,
    String? outlineBaseUrl,
    String? outlineApiKey,
    String? radicaleBaseUrl,
    String? radicaleUsername,
    String? radicalePassword,
    List<String> adminUuids = const [],
    String? kanMcpPath,
    String botName = 'Dreamfinder',
    String databasePath = './data/bot.db',
    String logLevel = 'info',
  }) =>
      Env._(
        anthropicApiKey: anthropicApiKey,
        signalApiUrl: signalApiUrl,
        signalPhoneNumber: signalPhoneNumber,
        kanBaseUrl: kanBaseUrl,
        kanApiKey: kanApiKey,
        outlineBaseUrl: outlineBaseUrl,
        outlineApiKey: outlineApiKey,
        radicaleBaseUrl: radicaleBaseUrl,
        radicaleUsername: radicaleUsername,
        radicalePassword: radicalePassword,
        adminUuids: adminUuids,
        kanMcpPath: kanMcpPath,
        botName: botName,
        databasePath: databasePath,
        logLevel: logLevel,
      );

  final String anthropicApiKey;
  final String signalApiUrl;
  final String signalPhoneNumber;
  final String? kanBaseUrl;
  final String? kanApiKey;
  final String? outlineBaseUrl;
  final String? outlineApiKey;
  final String? radicaleBaseUrl;
  final String? radicaleUsername;
  final String? radicalePassword;
  /// Signal UUIDs that have admin privileges (from `ADMIN_UUIDS` env var).
  final List<String> adminUuids;

  /// Path to the Kan MCP server entry point (from `KAN_MCP_PATH` env var).
  final String? kanMcpPath;
  final String botName;
  final String databasePath;
  final String logLevel;

  /// Returns `true` if [signalUuid] is in the configured admin list.
  bool isAdmin(String? signalUuid) =>
      signalUuid != null && adminUuids.contains(signalUuid);

  bool get kanEnabled => kanApiKey != null && kanApiKey!.isNotEmpty;
  bool get outlineEnabled => outlineApiKey != null && outlineApiKey!.isNotEmpty;
  bool get radicaleEnabled =>
      radicalePassword != null && radicalePassword!.isNotEmpty;

  /// Parses a comma-separated string into a trimmed list.
  static List<String> _parseList(String? value) {
    if (value == null || value.isEmpty) return const [];
    return value.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
  }
}
