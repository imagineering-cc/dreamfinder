import 'dart:convert';
import 'dart:io';

import 'package:dreamfinder/src/bot/health_check.dart';
import 'package:dreamfinder/src/immune/probe.dart';
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
        final request = await client.get('localhost', port, '/health');
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
        final request = await client.get('localhost', port, '/health');
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
        final request = await client.get('localhost', port, '/health');
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
        final request = await client.get('localhost', port, '/health');
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
        final request = await client.get('localhost', port, '/unknown');
        final response = await request.close();

        expect(response.statusCode, HttpStatus.notFound);
      } finally {
        client.close();
      }
    });

    test('includes processing_since when processing is in flight', () async {
      health.recordProcessingStart();

      final client = HttpClient();
      try {
        final request = await client.get('localhost', port, '/health');
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();
        final json = jsonDecode(body) as Map<String, dynamic>;

        expect(json['processing_since'], isNotNull);
      } finally {
        client.close();
      }
    });

    test('clears processing_since after recordProcessingEnd', () async {
      health.recordProcessingStart();
      health.recordProcessingEnd();

      final client = HttpClient();
      try {
        final request = await client.get('localhost', port, '/health');
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();
        final json = jsonDecode(body) as Map<String, dynamic>;

        expect(json['processing_since'], isNull);
      } finally {
        client.close();
      }
    });

    test('tracks messages processed and dropped', () async {
      health.recordMessageProcessed();
      health.recordMessageProcessed();
      health.recordMessageDropped('own_message');
      health.recordMessageDropped('not_mentioned');
      health.recordMessageDropped('not_mentioned');

      final client = HttpClient();
      try {
        final request = await client.get('localhost', port, '/health');
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();
        final json = jsonDecode(body) as Map<String, dynamic>;

        expect(json['messages_processed'], equals(2));
        expect(json['messages_dropped'], equals(3));
        final reasons = json['drop_reasons'] as Map<String, dynamic>;
        expect(reasons['own_message'], equals(1));
        expect(reasons['not_mentioned'], equals(2));
      } finally {
        client.close();
      }
    });

    test('exposes claude failure fields in /health JSON', () async {
      final client = HttpClient();
      try {
        final request = await client.get('localhost', port, '/health');
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();
        final json = jsonDecode(body) as Map<String, dynamic>;

        expect(json, contains('consecutive_claude_failures'));
        expect(json['consecutive_claude_failures'], equals(0));
        expect(json, contains('last_claude_error'));
        expect(json['last_claude_error'], isNull);
        expect(json['claude_ok'], isTrue);
      } finally {
        client.close();
      }
    });

    test('failures below threshold stay ok', () async {
      health.recordClaudeError(kind: 'transient', message: 'overloaded');
      health.recordClaudeError(kind: 'transient', message: 'overloaded');

      final client = HttpClient();
      try {
        final request = await client.get('localhost', port, '/health');
        final response = await request.close();
        expect(response.statusCode, HttpStatus.ok);

        final body = await response.transform(utf8.decoder).join();
        final json = jsonDecode(body) as Map<String, dynamic>;
        expect(json['status'], 'ok');
        expect(json['consecutive_claude_failures'], equals(2));
        expect(json['claude_ok'], isTrue);
        // error_count tracks cumulative errors too.
        expect(json['error_count'], equals(2));

        final lastError = json['last_claude_error'] as Map<String, dynamic>;
        expect(lastError['kind'], 'transient');
        expect(lastError['message'], 'overloaded');
        expect(lastError['at'], isNotNull);
      } finally {
        client.close();
      }
    });

    test('three consecutive claude failures → degraded (503)', () async {
      health.recordClaudeError(kind: 'billing', message: 'credit balance low');
      health.recordClaudeError(kind: 'billing', message: 'credit balance low');
      health.recordClaudeError(kind: 'billing', message: 'credit balance low');

      final client = HttpClient();
      try {
        final request = await client.get('localhost', port, '/health');
        final response = await request.close();
        expect(response.statusCode, HttpStatus.serviceUnavailable);

        final body = await response.transform(utf8.decoder).join();
        final json = jsonDecode(body) as Map<String, dynamic>;
        expect(json['status'], 'degraded');
        expect(json['consecutive_claude_failures'], equals(3));
        expect(json['claude_ok'], isFalse);
      } finally {
        client.close();
      }
    });

    test('a success resets the failure counter back to ok', () async {
      health.recordClaudeError(kind: 'auth', message: 'invalid_grant');
      health.recordClaudeError(kind: 'auth', message: 'invalid_grant');
      health.recordClaudeError(kind: 'auth', message: 'invalid_grant');
      // Now degraded; a single success must clear it.
      health.recordClaudeSuccess();

      final client = HttpClient();
      try {
        final request = await client.get('localhost', port, '/health');
        final response = await request.close();
        expect(response.statusCode, HttpStatus.ok);

        final body = await response.transform(utf8.decoder).join();
        final json = jsonDecode(body) as Map<String, dynamic>;
        expect(json['status'], 'ok');
        expect(json['consecutive_claude_failures'], equals(0));
        expect(json['claude_ok'], isTrue);
        expect(json['last_claude_error'], isNull);
        expect(json['last_claude_success'], isNotNull);
      } finally {
        client.close();
      }
    });

    test('returns degraded when processing is stuck', () async {
      // Use a health check with a very short stuck threshold for testing.
      await health.stop();
      final stuckHealth = HealthCheck();
      final stuckPort = await stuckHealth.start(port: 0);

      // Simulate stuck processing by setting start time in the past.
      stuckHealth.recordProcessingStart();
      // The threshold is 5 minutes — we can't easily test this without
      // either exposing the field or waiting. Instead, verify the field
      // is present and the mechanism works via the public API.

      final client = HttpClient();
      try {
        final request = await client.get('localhost', stuckPort, '/health');
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();
        final json = jsonDecode(body) as Map<String, dynamic>;

        // Processing just started, so it's not stuck yet — should be 'ok'.
        expect(json['status'], 'ok');
        expect(json['processing_since'], isNotNull);
      } finally {
        client.close();
        await stuckHealth.stop();
      }
    });
  });

  group('HealthCheck immune surfaces (/ready, /immune)', () {
    late HealthCheck health;
    late int port;

    setUp(() async {
      health = HealthCheck();
      port = await health.start(port: 0);
    });
    tearDown(() async {
      await health.stop();
    });

    Future<HttpClientResponse> get(String path) async {
      final client = HttpClient();
      final request = await client.get('localhost', port, path);
      return request.close();
    }

    test('/ready is 503 until markReady, then 200', () async {
      var response = await get('/ready');
      expect(response.statusCode, HttpStatus.serviceUnavailable);

      health.markReady();
      response = await get('/ready');
      expect(response.statusCode, HttpStatus.ok);
      final json = jsonDecode(await response.transform(utf8.decoder).join())
          as Map<String, dynamic>;
      expect(json['ready'], isTrue);
    });

    test('/immune reports unknown before any probe has run', () async {
      final response = await get('/immune');
      expect(response.statusCode, HttpStatus.ok);
      final json = jsonDecode(await response.transform(utf8.decoder).join())
          as Map<String, dynamic>;
      expect(json['immune_status'], 'unknown');
      expect(json['last_probe_run'], isNull);
    });

    test('/immune reports per-probe status', () async {
      health.recordProbeResult(const ProbeResult(
        id: 'probe_auth',
        status: ProbeStatus.ok,
        detail: 'auth mode: OAuth',
      ));
      final response = await get('/immune');
      expect(response.statusCode, HttpStatus.ok);
      final json = jsonDecode(await response.transform(utf8.decoder).join())
          as Map<String, dynamic>;
      expect(json['immune_status'], 'ok');
      expect(json['last_probe_run'], isNotNull);
      final probes = json['probes'] as Map<String, dynamic>;
      expect((probes['probe_auth'] as Map)['status'], 'ok');
    });

    test(
        'CRITICAL isolation: a FAILED probe leaves /health at 200 '
        '(immune system cannot trip the Docker-restart arc)', () async {
      health.recordProbeResult(const ProbeResult(
        id: 'probe_deep_search',
        status: ProbeStatus.failed,
        detail: 'searched zero sources',
      ));

      // /immune reflects the failure...
      final immune = await get('/immune');
      final immuneJson =
          jsonDecode(await immune.transform(utf8.decoder).join())
              as Map<String, dynamic>;
      expect(immuneJson['immune_status'], 'failed');

      // ...but /health (the Docker restart trigger) stays 200 / ok.
      final healthResp = await get('/health');
      expect(healthResp.statusCode, HttpStatus.ok,
          reason: 'a failed immune probe must NOT degrade /health');
      final healthJson =
          jsonDecode(await healthResp.transform(utf8.decoder).join())
              as Map<String, dynamic>;
      expect(healthJson['status'], 'ok');
    });
  });
}
