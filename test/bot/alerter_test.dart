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
  });
}
