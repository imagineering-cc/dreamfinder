import 'dart:async';
import 'dart:convert';

import 'package:dreamfinder/src/bot/alerter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

void main() {
  group('Alerter', () {
    late List<http.Request> notifyCalls;
    late List<(String, String)> roomSends;
    late DateTime now;

    http.Client buildClient() => http_testing.MockClient((request) async {
          notifyCalls.add(request);
          return http.Response('{"ok":true}', 200);
        });

    setUp(() {
      notifyCalls = [];
      roomSends = [];
      now = DateTime(2026, 5, 31, 12);
    });

    Alerter buildAlerter({
      String? notifyUrl = 'http://notify.test:8090',
      String? notifyApiKey = 'secret',
      String? announceRoomId = '!room:test',
      Duration cooldown = const Duration(hours: 1),
    }) =>
        Alerter(
          notifyUrl: notifyUrl,
          notifyApiKey: notifyApiKey,
          announceRoomId: announceRoomId,
          authModeLabel: 'API key (fallback)',
          httpClient: buildClient(),
          sendToRoom: (room, msg) async {
            roomSends.add((room, msg));
          },
          cooldown: cooldown,
          clock: () => now,
        );

    test('first escalate hits both channels', () async {
      final alerter = buildAlerter();
      await alerter.escalate(kind: 'billing', message: 'credit balance low');

      expect(notifyCalls, hasLength(1));
      expect(roomSends, hasLength(1));

      final req = notifyCalls.single;
      expect(req.method, 'POST');
      expect(req.url.path, '/send');
      expect(req.headers['authorization'], 'Bearer secret');
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      expect(body['message'], contains('billing'));
      expect(body['message'], contains('credit balance low'));
      expect(body['message'], contains('API key (fallback)'));
      expect(body, contains('parse_mode'));
      expect(body['parse_mode'], isNull);

      final (room, msg) = roomSends.single;
      expect(room, '!room:test');
      // Static, in-character — not agent-composed.
      expect(msg.toLowerCase(), contains('walkabout'));
    });

    test('second escalate for same kind within window is suppressed', () async {
      final alerter = buildAlerter();
      await alerter.escalate(kind: 'billing', message: 'low');
      now = now.add(const Duration(minutes: 30)); // still inside the hour
      await alerter.escalate(kind: 'billing', message: 'low again');

      expect(notifyCalls, hasLength(1));
      expect(roomSends, hasLength(1));
    });

    test('escalate after the cooldown window alerts again', () async {
      final alerter = buildAlerter();
      await alerter.escalate(kind: 'billing', message: 'low');
      now = now.add(const Duration(hours: 1, minutes: 1));
      await alerter.escalate(kind: 'billing', message: 'low');

      expect(notifyCalls, hasLength(2));
      expect(roomSends, hasLength(2));
    });

    test('different kinds dedup independently', () async {
      final alerter = buildAlerter();
      await alerter.escalate(kind: 'billing', message: 'low');
      await alerter.escalate(kind: 'auth', message: 'invalid_grant');

      expect(notifyCalls, hasLength(2));
      expect(roomSends, hasLength(2));
    });

    test('skips Telegram channel when notify not configured', () async {
      final alerter = buildAlerter(notifyUrl: null, notifyApiKey: null);
      await alerter.escalate(kind: 'billing', message: 'low');

      expect(notifyCalls, isEmpty);
      expect(roomSends, hasLength(1)); // in-room still fires
    });

    test('skips in-room channel when no announce room configured', () async {
      final alerter = buildAlerter(announceRoomId: null);
      await alerter.escalate(kind: 'billing', message: 'low');

      expect(notifyCalls, hasLength(1));
      expect(roomSends, isEmpty);
    });

    test('notify HTTP failure does not throw or block in-room', () async {
      final alerter = Alerter(
        notifyUrl: 'http://notify.test:8090',
        notifyApiKey: 'secret',
        announceRoomId: '!room:test',
        httpClient: http_testing.MockClient((_) async {
          throw http.ClientException('connection refused');
        }),
        sendToRoom: (room, msg) async => roomSends.add((room, msg)),
        clock: () => now,
      );

      await alerter.escalate(kind: 'auth', message: 'invalid_grant');
      // No throw; in-room channel still ran.
      expect(roomSends, hasLength(1));
    });

    test('in-room send failure does not throw', () async {
      final alerter = Alerter(
        notifyUrl: 'http://notify.test:8090',
        notifyApiKey: 'secret',
        announceRoomId: '!room:test',
        httpClient: buildClient(),
        sendToRoom: (room, msg) async {
          throw StateError('matrix down');
        },
        clock: () => now,
      );

      // Should complete without throwing.
      await alerter.escalate(kind: 'auth', message: 'invalid_grant');
      expect(notifyCalls, hasLength(1));
    });

    group('severity-aware framing', () {
      String telegramBody() => (jsonDecode(notifyCalls.single.body)
          as Map<String, dynamic>)['message'] as String;

      test('default severity is brainOffline — unchanged brain-offline frame',
          () async {
        final alerter = buildAlerter();
        await alerter.escalate(kind: 'billing', message: 'credit balance low');

        // Backward-compatible: same wording the pre-severity alerter produced.
        expect(telegramBody(), contains('brain offline'));
        expect(roomSends.single.$2.toLowerCase(), contains('walkabout'));
      });

      test('capabilityFailure pages both channels with a distinct honest frame',
          () async {
        final alerter = buildAlerter();
        await alerter.escalate(
          kind: 'probe_content_integrity',
          message: 'golden sentinel mismatch',
          severity: AlertSeverity.capabilityFailure,
        );

        // Operator sees it is a capability, not a dead brain.
        final body = telegramBody();
        expect(body, contains('probe_content_integrity'));
        expect(body, contains('golden sentinel mismatch'));
        expect(body.toLowerCase(), isNot(contains('brain offline')));
        expect(body.toLowerCase(), contains('capability'));

        // The room is warned NOT to trust River — but it is not told the brain
        // is dead (River is up, just wrong).
        expect(roomSends, hasLength(1));
        final roomMsg = roomSends.single.$2.toLowerCase();
        expect(roomMsg, isNot(contains('walkabout')));
        // ...and it must NOT name a specific subsystem the probe didn't convict:
        // a capability failure fires from any immune probe (content, calendar,
        // search, auth), so the room copy stays subsystem-agnostic. Naming
        // "memory" for a calendar-probe failure is the exact lie this PR kills.
        expect(roomMsg, isNot(contains('memory')));
        expect(roomMsg, isNot(contains('calendar')));
      });

      test('maintenance reaches operator only, never the room', () async {
        final alerter = buildAlerter();
        await alerter.escalate(
          kind: 'expired::probe_calendar',
          message: 'recalibration overdue',
          severity: AlertSeverity.maintenance,
        );

        // Operator gets a quiet nudge...
        expect(notifyCalls, hasLength(1));
        final body = telegramBody().toLowerCase();
        expect(body, isNot(contains('brain offline')));
        // ...and the community room is left undisturbed by a maintenance event.
        expect(roomSends, isEmpty);
      });

      test(
          'capabilityFailure re-fires after the urgent window, not the daily one',
          () async {
        final alerter = buildAlerter();
        await alerter.escalate(
          kind: 'probe_rag',
          message: 'hollow',
          severity: AlertSeverity.capabilityFailure,
        );
        // Just past the 1h urgent window — capability is urgent, not daily, so
        // it must re-page (guards against a future "make capability daily" slip).
        now = now.add(const Duration(hours: 1, minutes: 1));
        await alerter.escalate(
          kind: 'probe_rag',
          message: 'hollow',
          severity: AlertSeverity.capabilityFailure,
        );
        expect(notifyCalls, hasLength(2));
      });

      test(
          'concurrent same-key escalates page only once (no double-admit race)',
          () async {
        // Hold the first request in flight so the second escalate re-enters
        // while the first is mid-await — the exact interleave a boot smoke run
        // overlapping a scheduler tick produces.
        final gate = Completer<void>();
        var attempts = 0;
        final alerter = Alerter(
          notifyUrl: 'http://notify.test:8090',
          notifyApiKey: 'secret',
          announceRoomId: null,
          httpClient: http_testing.MockClient((_) async {
            attempts++;
            await gate.future;
            return http.Response('{"ok":true}', 200);
          }),
          clock: () => now,
        );
        final f1 = alerter.escalate(kind: 'billing', message: 'low');
        final f2 = alerter.escalate(kind: 'billing', message: 'low');
        gate.complete();
        await Future.wait([f1, f2]);
        // The provisional pre-await stamp meant the second call was suppressed
        // before it hit the wire — one page, not two.
        expect(attempts, 1);
      });

      test('a failed first delivery does NOT burn the cooldown', () async {
        // Telegram-only alerter (no room) whose sidecar is down: the first
        // maintenance page never lands. The 24h lease must NOT be stamped on a
        // spark that never left the coil — the next attempt must still fire.
        var attempts = 0;
        final alerter = Alerter(
          notifyUrl: 'http://notify.test:8090',
          notifyApiKey: 'secret',
          announceRoomId: null, // maintenance is operator-only anyway
          httpClient: http_testing.MockClient((_) async {
            attempts++;
            return http.Response('nope', 503); // sidecar cold
          }),
          clock: () => now,
        );
        await alerter.escalate(
          kind: 'expired::probe_calendar',
          message: 'overdue',
          severity: AlertSeverity.maintenance,
        );
        // Seconds later — a real retry, well inside the 24h window.
        now = now.add(const Duration(minutes: 1));
        await alerter.escalate(
          kind: 'expired::probe_calendar',
          message: 'overdue',
          severity: AlertSeverity.maintenance,
        );
        // Both attempts hit the wire — the failed page didn't lock out the retry.
        expect(attempts, 2);
      });

      test('maintenance nags daily, not hourly (longer cooldown)', () async {
        final alerter = buildAlerter();
        await alerter.escalate(
          kind: 'expired::probe_calendar',
          message: 'overdue',
          severity: AlertSeverity.maintenance,
        );
        // An hour later a brain-offline page would fire again; a standing
        // maintenance condition must not.
        now = now.add(const Duration(hours: 2));
        await alerter.escalate(
          kind: 'expired::probe_calendar',
          message: 'overdue',
          severity: AlertSeverity.maintenance,
        );
        expect(notifyCalls, hasLength(1));

        // But past a day it nudges again.
        now = now.add(const Duration(hours: 23));
        await alerter.escalate(
          kind: 'expired::probe_calendar',
          message: 'overdue',
          severity: AlertSeverity.maintenance,
        );
        expect(notifyCalls, hasLength(2));
      });
    });
  });
}
