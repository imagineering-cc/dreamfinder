import 'dart:convert';
import 'dart:io';

import 'package:dreamfinder/src/bot/health_check.dart';
import 'package:test/test.dart';

void main() {
  group('HealthCheck', () {
    late HealthCheck health;
    late int port;

    setUp(() async {
      health = HealthCheck();
      // Bind to port 0 so the OS picks an available port.
      port = await health.start(port: 0);
    });

    tearDown(() async {
      await health.stop();
    });

    test('responds 200 on /health with status fields', () async {
      final client = HttpClient();
      try {
        final request =
            await client.get('localhost', port, '/health');
        final response = await request.close();

        expect(response.statusCode, HttpStatus.ok);

        final body = await response.transform(utf8.decoder).join();
        final json = jsonDecode(body) as Map<String, dynamic>;

        expect(json['status'], 'ok');
        expect(json['version'], 'dev');
        expect(json['commit'], 'local');
        expect(json['build_time'], 'unknown');
        expect(json['uptime_seconds'], isA<int>());
        expect(json, contains('last_poll'));
        expect(json, contains('last_claude_success'));
        expect(json, contains('error_count'));
      } finally {
        client.close();
      }
    });

    test('reflects recorded poll time', () async {
      health.recordPoll();

      final client = HttpClient();
      try {
        final request =
            await client.get('localhost', port, '/health');
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();
        final json = jsonDecode(body) as Map<String, dynamic>;

        expect(json['last_poll'], isNotNull);
      } finally {
        client.close();
      }
    });

    test('reflects recorded Claude success', () async {
      health.recordClaudeSuccess();

      final client = HttpClient();
      try {
        final request =
            await client.get('localhost', port, '/health');
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();
        final json = jsonDecode(body) as Map<String, dynamic>;

        expect(json['last_claude_success'], isNotNull);
      } finally {
        client.close();
      }
    });

    test('increments error count', () async {
      health.recordError();
      health.recordError();

      final client = HttpClient();
      try {
        final request =
            await client.get('localhost', port, '/health');
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();
        final json = jsonDecode(body) as Map<String, dynamic>;

        expect(json['error_count'], 2);
      } finally {
        client.close();
      }
    });

    test('returns degraded status when poll is stale', () async {
      // Create a health check with a very short stale threshold.
      await health.stop();
      health = HealthCheck(stalePollThreshold: Duration.zero);
      port = await health.start(port: 0);

      // Record a poll — it will immediately be "stale" with zero threshold.
      health.recordPoll();

      final client = HttpClient();
      try {
        final request = await client.get('localhost', port, '/health');
        final response = await request.close();

        expect(response.statusCode, HttpStatus.serviceUnavailable);

        final body = await response.transform(utf8.decoder).join();
        final json = jsonDecode(body) as Map<String, dynamic>;
        expect(json['status'], 'degraded');
      } finally {
        client.close();
      }
    });

    test('includes custom version info in response', () async {
      await health.stop();
      health = HealthCheck(
        version: '0.1.0+abc1234',
        commit: 'abc1234',
        buildTime: '2026-03-09T12:00:00Z',
      );
      port = await health.start(port: 0);

      final client = HttpClient();
      try {
        final request = await client.get('localhost', port, '/health');
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();
        final json = jsonDecode(body) as Map<String, dynamic>;

        expect(json['version'], '0.1.0+abc1234');
        expect(json['commit'], 'abc1234');
        expect(json['build_time'], '2026-03-09T12:00:00Z');
      } finally {
        client.close();
      }
    });

    test('returns 404 for unknown paths', () async {
      final client = HttpClient();
      try {
        final request =
            await client.get('localhost', port, '/unknown');
        final response = await request.close();

        expect(response.statusCode, HttpStatus.notFound);
      } finally {
        client.close();
      }
    });
  });
}
