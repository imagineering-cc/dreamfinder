/// Structured JSON logger with level filtering.
///
/// Outputs one JSON object per line to [sink] (defaults to stderr).
/// Each log entry includes `timestamp`, `level`, `logger`, and `message`.
/// Optional [extra] fields are merged into the top-level JSON object.
///
/// Also forwards to `dart:developer` log so Dart DevTools still works.
library;

import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

/// Log severity levels, ordered from most to least verbose.
enum LogLevel {
  debug,
  info,
  warning,
  error;

  /// Parses a string like `"info"` or `"WARNING"` into a [LogLevel].
  ///
  /// Returns [LogLevel.info] and prints a warning to stderr for
  /// unrecognized strings (catches typos in `LOG_LEVEL` env var).
  static LogLevel fromString(String value) {
    final lower = value.toLowerCase();
    for (final level in values) {
      if (level.name == lower) return level;
    }
    if (value.isNotEmpty) {
      stderr.writeln(
        'WARNING: Unknown log level "$value", defaulting to "info". '
        'Valid levels: ${values.map((l) => l.name).join(", ")}',
      );
    }
    return LogLevel.info;
  }
}

/// A structured JSON logger.
///
/// Create a root logger in the entry point and derive child loggers
/// (with their own `name`) via [child]:
///
/// ```dart
/// final log = BotLogger(name: 'Main', level: LogLevel.info);
/// final schedulerLog = log.child('Scheduler');
/// ```
class BotLogger {
  /// Creates a logger.
  ///
  /// [sink] receives one JSON-encoded line per log entry. Defaults to
  /// [stderr.writeln] for Docker / Cloud Logging compatibility.
  BotLogger({
    required this.name,
    required this.level,
    void Function(String line)? sink,
  }) : _sink = sink ?? stderr.writeln;

  final String name;
  final LogLevel level;
  final void Function(String line) _sink;

  /// Creates a child logger that shares this logger's level and sink.
  BotLogger child(String childName) =>
      BotLogger(name: childName, level: level, sink: _sink);

  void debug(String message, {Map<String, Object?>? extra}) =>
      _log(LogLevel.debug, message, extra);

  void info(String message, {Map<String, Object?>? extra}) =>
      _log(LogLevel.info, message, extra);

  void warning(String message, {Map<String, Object?>? extra}) =>
      _log(LogLevel.warning, message, extra);

  void error(String message, {Map<String, Object?>? extra}) =>
      _log(LogLevel.error, message, extra);

  void _log(LogLevel msgLevel, String message, Map<String, Object?>? extra) {
    if (msgLevel.index < level.index) return;

    final entry = <String, Object?>{
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'level': msgLevel.name,
      'logger': name,
      'message': message,
      if (extra != null) 'data': extra,
    };

    _sink(jsonEncode(entry));

    // Mirror to dart:developer so DevTools log inspector still works.
    developer.log(
      message,
      name: name,
      level: switch (msgLevel) {
        LogLevel.debug => 0,
        LogLevel.info => 0,
        LogLevel.warning => 900,
        LogLevel.error => 1000,
      },
    );
  }
}
