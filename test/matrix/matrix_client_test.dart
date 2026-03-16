import 'dart:convert';

import 'package:dreamfinder/src/matrix/matrix_client.dart';
import 'package:dreamfinder/src/matrix/models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

/// Creates a mock HTTP client that responds based on the request path.
http_testing.MockClient _mockClient(
  Map<String, http.Response Function(http.Request)> handlers,
) {
  return http_testing.MockClient((request) async {
    final path = request.url.path;
    for (final entry in handlers.entries) {
      if (path.contains(entry.key)) {
        return entry.value(request);
      }
    }
    return http.Response('Not found', 404);
  });
}

http.Response _jsonResponse(Map<String, dynamic> body, {int status = 200}) {
  return http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );
}

void main() {
  const homeserver = 'https://matrix.test';
  const token = 'test-token';

  group('MatrixClient', () {
    test('whoAmI returns bot user ID', () async {
      final client = MatrixClient(
        homeserver: homeserver,
        accessToken: token,
        client: _mockClient({
          'whoami': (_) => _jsonResponse({'user_id': '@bot:test'}),
        }),
      );

      final userId = await client.whoAmI();
      expect(userId, '@bot:test');

      // Cached on second call.
      final cached = await client.whoAmI();
      expect(cached, '@bot:test');
    });

    test('sync parses timeline events', () async {
      final syncResponse = <String, dynamic>{
        'next_batch': 'batch_2',
        'rooms': {
          'join': {
            '!room1:test': {
              'timeline': {
                'events': [
                  {
                    'event_id': '\$evt1',
                    'sender': '@alice:test',
                    'type': 'm.room.message',
                    'origin_server_ts': 1710000000000,
                    'content': {
                      'msgtype': 'm.text',
                      'body': 'Hello!',
                      'format': 'org.matrix.custom.html',
                      'formatted_body': '<b>Hello!</b>',
                    },
                  },
                ],
              },
              'summary': {
                'm.joined_member_count': 3,
              },
            },
          },
        },
      };

      final client = MatrixClient(
        homeserver: homeserver,
        accessToken: token,
        client: _mockClient({
          'sync': (_) => _jsonResponse(syncResponse),
        }),
      );

      final result = await client.sync(since: 'batch_1');
      expect(result.nextBatch, 'batch_2');
      expect(result.events, hasLength(1));

      final event = result.events.first;
      expect(event.roomId, '!room1:test');
      expect(event.sender, '@alice:test');
      expect(event.body, 'Hello!');
      expect(event.formattedBody, '<b>Hello!</b>');
      expect(event.hasTextMessage, isTrue);
      expect(event.msgType, 'm.text');
    });

    test('sync parses invites', () async {
      final syncResponse = <String, dynamic>{
        'next_batch': 'batch_2',
        'rooms': {
          'invite': {
            '!invited:test': {
              'invite_state': {
                'events': [
                  {
                    'type': 'm.room.member',
                    'sender': '@inviter:test',
                    'content': {'membership': 'invite'},
                  },
                ],
              },
            },
          },
        },
      };

      final client = MatrixClient(
        homeserver: homeserver,
        accessToken: token,
        client: _mockClient({
          'sync': (_) => _jsonResponse(syncResponse),
        }),
      );

      final result = await client.sync(since: 'batch_1');
      expect(result.invites, hasLength(1));
      expect(result.invites.first.roomId, '!invited:test');
      expect(result.invites.first.inviter, '@inviter:test');
    });

    test('DM detection — 2 members = DM', () async {
      final syncResponse = <String, dynamic>{
        'next_batch': 'batch_2',
        'rooms': {
          'join': {
            '!dm:test': {
              'timeline': {'events': <dynamic>[]},
              'summary': {'m.joined_member_count': 2},
            },
            '!group:test': {
              'timeline': {'events': <dynamic>[]},
              'summary': {'m.joined_member_count': 5},
            },
          },
        },
      };

      final client = MatrixClient(
        homeserver: homeserver,
        accessToken: token,
        client: _mockClient({
          'sync': (_) => _jsonResponse(syncResponse),
        }),
      );

      await client.sync(since: 'batch_1');

      expect(client.isDm('!dm:test'), isTrue);
      expect(client.isDm('!group:test'), isFalse);
      expect(client.isDm('!unknown:test'), isFalse);
    });

    test('sendMessage sends with formatted body', () async {
      http.Request? capturedRequest;

      final client = MatrixClient(
        homeserver: homeserver,
        accessToken: token,
        client: _mockClient({
          'send': (req) {
            capturedRequest = req;
            return _jsonResponse({'event_id': '\$sent1'});
          },
        }),
      );

      final eventId = await client.sendMessage(
        roomId: '!room:test',
        message: 'Hello\nWorld',
      );

      expect(eventId, '\$sent1');
      expect(capturedRequest, isNotNull);
      expect(capturedRequest!.method, 'PUT');

      final body =
          jsonDecode(capturedRequest!.body) as Map<String, dynamic>;
      expect(body['msgtype'], 'm.text');
      expect(body['body'], 'Hello\nWorld');
      expect(body['formatted_body'], contains('<br/>'));
    });

    test('joinRoom sends POST to join endpoint', () async {
      http.Request? capturedRequest;

      final client = MatrixClient(
        homeserver: homeserver,
        accessToken: token,
        client: _mockClient({
          'join': (req) {
            capturedRequest = req;
            return _jsonResponse({'room_id': '!joined:test'});
          },
        }),
      );

      await client.joinRoom('!room:test');
      expect(capturedRequest, isNotNull);
      expect(capturedRequest!.method, 'POST');
    });

    test('sendTypingIndicator sends PUT', () async {
      http.Request? capturedRequest;

      final client = MatrixClient(
        homeserver: homeserver,
        accessToken: token,
        client: _mockClient({
          'whoami': (_) => _jsonResponse({'user_id': '@bot:test'}),
          'typing': (req) {
            capturedRequest = req;
            return _jsonResponse(<String, dynamic>{});
          },
        }),
      );

      await client.sendTypingIndicator(roomId: '!room:test');
      expect(capturedRequest, isNotNull);
      expect(capturedRequest!.method, 'PUT');

      final body =
          jsonDecode(capturedRequest!.body) as Map<String, dynamic>;
      expect(body['typing'], isTrue);
    });

    test('mention detection — Matrix pill', () async {
      final client = MatrixClient(
        homeserver: homeserver,
        accessToken: token,
        client: _mockClient({
          'whoami': (_) => _jsonResponse({'user_id': '@dreamfinder:test'}),
        }),
      );

      // Populate _botUserId.
      await client.whoAmI();

      expect(
        client.isMentioned(
          text: 'Hey Dreamfinder',
          formattedBody:
              '<a href="https://matrix.to/#/@dreamfinder:test">Dreamfinder</a> hey',
          botDisplayName: 'Dreamfinder',
        ),
        isTrue,
      );
    });

    test('mention detection — display name regex', () {
      final client = MatrixClient(
        homeserver: homeserver,
        accessToken: token,
      );

      expect(
        client.isMentioned(
          text: 'Hey dreamfinder, what is up?',
          botDisplayName: 'Dreamfinder',
        ),
        isTrue,
      );

      expect(
        client.isMentioned(
          text: 'Hello world',
          botDisplayName: 'Dreamfinder',
        ),
        isFalse,
      );
    });

    test('initial sync skips timeline events', () async {
      http.Request? capturedRequest;

      final client = MatrixClient(
        homeserver: homeserver,
        accessToken: token,
        client: _mockClient({
          'sync': (req) {
            capturedRequest = req;
            return _jsonResponse({
              'next_batch': 'initial_batch',
              'rooms': <String, dynamic>{},
            });
          },
        }),
      );

      // Initial sync — no `since` parameter.
      await client.sync();

      // Should include a filter that limits timeline to 0.
      final filter = capturedRequest!.url.queryParameters['filter'];
      expect(filter, isNotNull);
      final filterJson = jsonDecode(filter!) as Map<String, dynamic>;
      final roomFilter = filterJson['room'] as Map<String, dynamic>;
      final timelineFilter = roomFilter['timeline'] as Map<String, dynamic>;
      expect(timelineFilter['limit'], 0);
    });

    test('throws MatrixApiException on error status', () async {
      final client = MatrixClient(
        homeserver: homeserver,
        accessToken: token,
        client: _mockClient({
          'whoami': (_) => http.Response('{"errcode":"M_UNKNOWN_TOKEN"}', 401),
        }),
      );

      expect(
        () => client.whoAmI(),
        throwsA(isA<MatrixApiException>()),
      );
    });

    test('sync handles empty response', () async {
      final client = MatrixClient(
        homeserver: homeserver,
        accessToken: token,
        client: _mockClient({
          'sync': (_) => _jsonResponse({
                'next_batch': 'empty_batch',
              }),
        }),
      );

      final result = await client.sync(since: 'prev');
      expect(result.nextBatch, 'empty_batch');
      expect(result.events, isEmpty);
      expect(result.invites, isEmpty);
    });
  });

  group('MatrixEvent', () {
    test('hasTextMessage is false for non-text events', () {
      final event = MatrixEvent(
        eventId: '\$1',
        roomId: '!r:t',
        sender: '@u:t',
        type: 'm.room.member',
        originServerTs: 0,
        content: const {'membership': 'join'},
      );
      expect(event.hasTextMessage, isFalse);
    });

    test('hasTextMessage is false for image messages', () {
      final event = MatrixEvent(
        eventId: '\$1',
        roomId: '!r:t',
        sender: '@u:t',
        type: 'm.room.message',
        originServerTs: 0,
        content: const {'msgtype': 'm.image', 'body': 'photo.jpg'},
      );
      expect(event.hasTextMessage, isFalse);
    });
  });
}
