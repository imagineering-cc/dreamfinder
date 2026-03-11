/// Simple HTTP health check endpoint for liveness probes.
///
/// Reports uptime, last poll time, last successful Claude API call, and
/// cumulative error count. Designed for Docker `healthcheck:` directives
/// and GCP load balancer health probes.
library;

import 'dart:convert';
import 'dart:io';

/// HTTP health check server.
///
/// Call [recordPoll], [recordClaudeSuccess], and [recordError] from the
/// main event loop to keep the health status current.
/// Default threshold: if no poll for 2 minutes, report degraded.
const _defaultStalePollThreshold = Duration(minutes: 2);

class HealthCheck {
  HealthCheck({
    Duration stalePollThreshold = _defaultStalePollThreshold,
    this.version = 'dev',
    this.commit = 'local',
    this.buildTime = 'unknown',
  }) : _stalePollThreshold = stalePollThreshold;

  /// Semver + short SHA, e.g. `0.1.0+abc1234`.
  final String version;

  /// Git commit SHA baked in at build time.
  final String commit;

  /// ISO 8601 UTC timestamp of the Docker build.
  final String buildTime;

  final Duration _stalePollThreshold;
  final DateTime _startTime = DateTime.now();
  HttpServer? _server;

  DateTime? _lastPoll;
  DateTime? _lastClaudeSuccess;
  int _errorCount = 0;

  /// Starts the health check HTTP server.
  ///
  /// Returns the actual port (useful when [port] is `0` for tests).
  Future<int> start({int port = 8081}) async {
    _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _server!.listen(_handleRequest);
    return _server!.port;
  }

  /// Stops the health check server.
  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  /// Records a successful poll cycle.
  void recordPoll() {
    _lastPoll = DateTime.now();
  }

  /// Records a successful Claude API response.
  void recordClaudeSuccess() {
    _lastClaudeSuccess = DateTime.now();
  }

  /// Increments the cumulative error counter.
  void recordError() {
    _errorCount++;
  }

  void _handleRequest(HttpRequest request) {
    if (request.uri.path == '/health') {
      final now = DateTime.now();
      final uptime = now.difference(_startTime);
      final pollStale = _lastPoll != null &&
          now.difference(_lastPoll!) >= _stalePollThreshold;
      final status = pollStale ? 'degraded' : 'ok';

      request.response
        ..statusCode = pollStale
            ? HttpStatus.serviceUnavailable
            : HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(<String, Object?>{
          'status': status,
          'version': version,
          'commit': commit,
          'build_time': buildTime,
          'uptime_seconds': uptime.inSeconds,
          'last_poll': _lastPoll?.toUtc().toIso8601String(),
          'last_claude_success':
              _lastClaudeSuccess?.toUtc().toIso8601String(),
          'error_count': _errorCount,
        }))
        ..close();
    } else {
      request.response
        ..statusCode = HttpStatus.notFound
        ..close();
    }
  }
}
