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

    test('ensureMemberCount backfills DM detection on a cache miss', () async {
      // No sync has run, so the room's count is unknown and isDm is false —
      // the bug that made DMs joined before this process require a mention.
      final client = MatrixClient(
        homeserver: homeserver,
        accessToken: token,
        client: _mockClient({
          'joined_members': (_) => _jsonResponse({
                'joined': {
                  '@bot:test': <String, dynamic>{},
                  '@human:test': <String, dynamic>{},
                },
              }),
        }),
      );

      expect(client.isDm('!stale-dm:test'), isFalse,
          reason: 'unknown count → treated as group');

      await client.ensureMemberCount('!stale-dm:test');

      expect(client.isDm('!stale-dm:test'), isTrue,
          reason: 'backfilled 2-member count → detected as DM');
    });

    test('ensureMemberCount counts >2 members as a group', () async {
      final client = MatrixClient(
        homeserver: homeserver,
        accessToken: token,
        client: _mockClient({
          'joined_members': (_) => _jsonResponse({
                'joined': {
                  '@bot:test': <String, dynamic>{},
                  '@a:test': <String, dynamic>{},
                  '@b:test': <String, dynamic>{},
                },
              }),
        }),
      );

      await client.ensureMemberCount('!room:test');
      expect(client.isDm('!room:test'), isFalse);
    });

    // The Portal Member-Count Trap: a mautrix bridge portal for a 1:1 chat
    // contains the bot, the remote user's ghost, AND the bridge bot — raw
    // count 3 → misclassified as a group → the bot ignores the person's
    // reply (they won't type the bot's name into WhatsApp). Excluding bridge
    // bots from the effective count defuses this.
    test('portal room counts as DM when bridge bot is excluded', () async {
      final client = MatrixClient(
        homeserver: homeserver,
        accessToken: token,
        bridgeBotIds: {'@whatsappbot:test'},
        client: _mockClient({
          'joined_members': (_) => _jsonResponse({
                'joined': {
                  '@bot:test': <String, dynamic>{},
                  '@whatsapp_61400000000:test': <String, dynamic>{},
                  '@whatsappbot:test': <String, dynamic>{},
                },
              }),
        }),
      );

      await client.ensureMemberCount('!portal:test');
      expect(client.isDm('!portal:test'), isTrue,
          reason: 'bot + ghost + bridge bot → effective 2 → DM');
    });

    test('bridge management room is NOT a DM (effective count 1)', () async {
      // The room where the bot talks to the bridge bot itself: raw count 2
      // would classify it as a DM and the bot would chat with the bridge's
      // command output. Excluding the bridge bot makes the effective count 1.
      final client = MatrixClient(
        homeserver: homeserver,
        accessToken: token,
        bridgeBotIds: {'@whatsappbot:test'},
        client: _mockClient({
          'joined_members': (_) => _jsonResponse({
                'joined': {
                  '@bot:test': <String, dynamic>{},
                  '@whatsappbot:test': <String, dynamic>{},
                },
              }),
        }),
      );

      await client.ensureMemberCount('!mgmt:test');
      expect(client.isDm('!mgmt:test'), isFalse);
    });

    test('multi-member portal still counts as a group', () async {
      final client = MatrixClient(
        homeserver: homeserver,
        accessToken: token,
        bridgeBotIds: {'@whatsappbot:test'},
        client: _mockClient({
          'joined_members': (_) => _jsonResponse({
                'joined': {
                  '@bot:test': <String, dynamic>{},
                  '@whatsapp_111:test': <String, dynamic>{},
                  '@whatsapp_222:test': <String, dynamic>{},
                  '@whatsappbot:test': <String, dynamic>{},
                },
              }),
        }),
      );

      await client.ensureMemberCount('!wagroup:test');
      expect(client.isDm('!wagroup:test'), isFalse,
          reason: 'bot + 2 ghosts + bridge bot → effective 3 → group');
    });

    test(
        'with bridge bots configured, a summary count change invalidates the '
        'effective count and triggers a member-list refetch', () async {
      var fetchCount = 0;
      final syncResponse = <String, dynamic>{
        'next_batch': 'batch_2',
        'rooms': {
          'join': {
            '!portal:test': {
              'timeline': {'events': <dynamic>[]},
              'summary': {'m.joined_member_count': 3},
            },
          },
        },
      };

      final client = MatrixClient(
        homeserver: homeserver,
        accessToken: token,
        bridgeBotIds: {'@whatsappbot:test'},
        client: _mockClient({
          'joined_members': (_) {
            fetchCount++;
            return _jsonResponse({
              'joined': {
                '@bot:test': <String, dynamic>{},
                '@whatsapp_61400000000:test': <String, dynamic>{},
                '@whatsappbot:test': <String, dynamic>{},
              },
            });
          },
          'sync': (_) => _jsonResponse(syncResponse),
        }),
      );

      // Backfill, then a summary arrives (membership changed) — the cached
      // effective count must be dropped and recomputed from the member list,
      // NOT overwritten with the raw count (which includes the bridge bot).
      await client.ensureMemberCount('!portal:test');
      expect(client.isDm('!portal:test'), isTrue);
      expect(fetchCount, 1);

      await client.sync(since: 'batch_1');
      expect(client.isDm('!portal:test'), isFalse,
          reason: 'invalidated → unknown → safe group default until refetch');

      await client.ensureMemberCount('!portal:test');
      expect(fetchCount, 2, reason: 'invalidation must trigger a refetch');
      expect(client.isDm('!portal:test'), isTrue);
    });

    test('without bridge bots, summary counts still populate the cache',
        () async {
      // No-regression guard: the pre-bridge behavior (summary → cache,
      // zero extra HTTP) must be preserved when BRIDGE_BOT_IDS is unset.
      var fetchCount = 0;
      final client = MatrixClient(
        homeserver: homeserver,
        accessToken: token,
        client: _mockClient({
          'joined_members': (_) {
            fetchCount++;
            return _jsonResponse({'joined': <String, dynamic>{}});
          },
          'sync': (_) => _jsonResponse({
                'next_batch': 'batch_2',
                'rooms': {
                  'join': {
                    '!dm:test': {
                      'timeline': {'events': <dynamic>[]},
                      'summary': {'m.joined_member_count': 2},
                    },
                  },
                },
              }),
        }),
      );

      await client.sync(since: 'batch_1');
      expect(client.isDm('!dm:test'), isTrue);

      await client.ensureMemberCount('!dm:test');
      expect(fetchCount, 0, reason: 'summary filled the cache — no refetch');
    });

    test('getRecentMessages fetches newest-first with dir=b', () async {
      http.Request? capturedRequest;
      final client = MatrixClient(
        homeserver: homeserver,
        accessToken: token,
        client: _mockClient({
          'messages': (req) {
            capturedRequest = req;
            return _jsonResponse({
              'chunk': [
                {
                  'event_id': r'$newest',
                  'sender': '@whatsappbot:test',
                  'type': 'm.room.message',
                  'origin_server_ts': 2,
                  'content': {'msgtype': 'm.text', 'body': 'reply'},
                },
                {
                  'event_id': r'$older',
                  'sender': '@bot:test',
                  'type': 'm.room.message',
                  'origin_server_ts': 1,
                  'content': {'msgtype': 'm.text', 'body': 'command'},
                },
              ],
            });
          },
        }),
      );

      final messages = await client.getRecentMessages(roomId: '!mgmt:test');
      expect(messages, hasLength(2));
      expect(messages.first.eventId, r'$newest');
      expect(messages.first.body, 'reply');
      expect(capturedRequest!.url.queryParameters['dir'], 'b');
    });

    test('ensureMemberCount negative-caches on failure (probes at most once)',
        () async {
      var fetchCount = 0;
      final client = MatrixClient(
        homeserver: homeserver,
        accessToken: token,
        client: _mockClient({
          'joined_members': (_) {
            fetchCount++;
            return http.Response('boom', 500);
          },
        }),
      );

      await client.ensureMemberCount('!room:test');
      await client
          .ensureMemberCount('!room:test'); // second call must NOT refetch
      expect(fetchCount, 1,
          reason: 'failure is cached → no retry spam in the event loop');
      expect(client.isDm('!room:test'), isFalse,
          reason: 'failed fetch → sentinel → safe default (group)');
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

      final body = jsonDecode(capturedRequest!.body) as Map<String, dynamic>;
      expect(body['msgtype'], 'm.text');
      expect(body['body'], 'Hello\nWorld');
      expect(body['formatted_body'], contains('<br/>'));
    });

    test('sendMessage converts Markdown to HTML', () async {
      http.Request? capturedRequest;

      final client = MatrixClient(
        homeserver: homeserver,
        accessToken: token,
        client: _mockClient({
          'send': (req) {
            capturedRequest = req;
            return _jsonResponse({'event_id': '\$sent2'});
          },
        }),
      );

      await client.sendMessage(
        roomId: '!room:test',
        message: '**bold** and *italic* and `code`',
      );

      final body = jsonDecode(capturedRequest!.body) as Map<String, dynamic>;
      final html = body['formatted_body'] as String;
      expect(html, contains('<strong>bold</strong>'));
      expect(html, contains('<em>italic</em>'));
      expect(html, contains('<code>code</code>'));
    });

    test('createDm sends POST with is_direct and invite', () async {
      http.Request? capturedRequest;

      final client = MatrixClient(
        homeserver: homeserver,
        accessToken: token,
        client: _mockClient({
          'createRoom': (req) {
            capturedRequest = req;
            return _jsonResponse({'room_id': '!dm:test'});
          },
        }),
      );

      final roomId = await client.createDm('@user:test');

      expect(roomId, '!dm:test');
      expect(capturedRequest, isNotNull);
      expect(capturedRequest!.method, 'POST');

      final body = jsonDecode(capturedRequest!.body) as Map<String, dynamic>;
      expect(body['is_direct'], isTrue);
      expect(body['invite'], contains('@user:test'));
      expect(body['preset'], 'trusted_private_chat');
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

      final body = jsonDecode(capturedRequest!.body) as Map<String, dynamic>;
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

    // Regression test for the PR #84 family: on a fresh deploy (no persisted
    // sync token), any timeline events the homeserver returns must NOT surface
    // to the caller — regardless of whether the server-side filter was honoured.
    //
    // The server-side filter (`timeline.limit: 0`) is the primary guard, but a
    // non-compliant or race-y homeserver could still include stale history.
    // The client therefore drops timeline events from the parsed response when
    // `since` is null, preventing historical member-join events from triggering
    // spurious welcome messages.
    test('initial sync suppresses timeline events even if server returns them',
        () async {
      // Simulate a homeserver that ignores the filter and returns a member-join
      // event from history (e.g., a user who joined 2 hours before the bot started).
      final syncWithHistoricalJoin = <String, dynamic>{
        'next_batch': 'initial_batch',
        'rooms': {
          'join': {
            '!room:test': {
              'timeline': {
                'events': [
                  {
                    'event_id': r'$historical_join',
                    'sender': '@alice:test',
                    'type': 'm.room.member',
                    'origin_server_ts': 1710000000000,
                    'content': {
                      'membership': 'join',
                      'displayname': 'Alice',
                    },
                  },
                ],
              },
              'summary': {'m.joined_member_count': 3},
            },
          },
        },
      };

      final client = MatrixClient(
        homeserver: homeserver,
        accessToken: token,
        client: _mockClient({
          'sync': (_) => _jsonResponse(syncWithHistoricalJoin),
        }),
      );

      // Initial sync — no `since` parameter.
      final result = await client.sync();

      // Despite the server returning a member-join event, it must not appear
      // in the response so the welcome handler in dreamfinder.dart is never reached.
      expect(
        result.events,
        isEmpty,
        reason:
            'Historical joins from initial sync must not reach the welcome handler',
      );

      // Member counts are still parsed (needed for DM detection).
      expect(result.roomMemberCounts['!room:test'], 3);
    });

    test(
        'incremental sync (with since token) surfaces member-join events normally',
        () async {
      // Confirm the guard is NOT applied to incremental syncs — real joins
      // that happen after the bot is running must still trigger welcomes.
      final syncWithNewJoin = <String, dynamic>{
        'next_batch': 'batch_2',
        'rooms': {
          'join': {
            '!room:test': {
              'timeline': {
                'events': [
                  {
                    'event_id': r'$live_join',
                    'sender': '@bob:test',
                    'type': 'm.room.member',
                    'origin_server_ts': 1710000000001,
                    'content': {
                      'membership': 'join',
                      'displayname': 'Bob',
                    },
                  },
                ],
              },
              'summary': {'m.joined_member_count': 4},
            },
          },
        },
      };

      final client = MatrixClient(
        homeserver: homeserver,
        accessToken: token,
        client: _mockClient({
          'sync': (_) => _jsonResponse(syncWithNewJoin),
        }),
      );

      // Incremental sync — `since` token is present.
      final result = await client.sync(since: 'batch_1');

      expect(result.events, hasLength(1));
      final event = result.events.first;
      expect(event.isMemberJoin, isTrue);
      expect(event.memberDisplayName, 'Bob');
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
        client.whoAmI,
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
      final event = const MatrixEvent(
        eventId: '\$1',
        roomId: '!r:t',
        sender: '@u:t',
        type: 'm.room.member',
        originServerTs: 0,
        content: {'membership': 'join'},
      );
      expect(event.hasTextMessage, isFalse);
    });

    test('hasTextMessage is false for image messages', () {
      final event = const MatrixEvent(
        eventId: '\$1',
        roomId: '!r:t',
        sender: '@u:t',
        type: 'm.room.message',
        originServerTs: 0,
        content: {'msgtype': 'm.image', 'body': 'photo.jpg'},
      );
      expect(event.hasTextMessage, isFalse);
    });

    test('isMemberJoin is true for join membership events', () {
      final event = const MatrixEvent(
        eventId: '\$1',
        roomId: '!r:t',
        sender: '@newuser:t',
        type: 'm.room.member',
        originServerTs: 0,
        content: {
          'membership': 'join',
          'displayname': 'New User',
        },
      );
      expect(event.isMemberJoin, isTrue);
      expect(event.memberDisplayName, 'New User');
    });

    test('isMemberJoin is false for leave events', () {
      final event = const MatrixEvent(
        eventId: '\$1',
        roomId: '!r:t',
        sender: '@leaving:t',
        type: 'm.room.member',
        originServerTs: 0,
        content: {'membership': 'leave'},
      );
      expect(event.isMemberJoin, isFalse);
    });

    test('isMemberJoin is false for text messages', () {
      final event = const MatrixEvent(
        eventId: '\$1',
        roomId: '!r:t',
        sender: '@u:t',
        type: 'm.room.message',
        originServerTs: 0,
        content: {'msgtype': 'm.text', 'body': 'hello'},
      );
      expect(event.isMemberJoin, isFalse);
    });

    test('isMemberJoin is false for displayname-update re-emit', () {
      // Matrix re-emits m.room.member with membership=join when a user
      // changes their displayname or avatar. prev_content.membership=join
      // signals "already a member, just a profile update".
      final event = const MatrixEvent(
        eventId: '\$1',
        roomId: '!r:t',
        sender: '@existing:t',
        type: 'm.room.member',
        originServerTs: 0,
        content: {
          'membership': 'join',
          'displayname': 'New Name',
        },
        prevContent: {
          'membership': 'join',
          'displayname': 'Old Name',
        },
      );
      expect(event.isMemberJoin, isFalse);
    });

    test('isMemberJoin is true for join after leave (rejoin)', () {
      final event = const MatrixEvent(
        eventId: '\$1',
        roomId: '!r:t',
        sender: '@rejoiner:t',
        type: 'm.room.member',
        originServerTs: 0,
        content: {'membership': 'join'},
        prevContent: {'membership': 'leave'},
      );
      expect(event.isMemberJoin, isTrue);
    });

    test('fromJson extracts prev_content from unsigned wrapper', () {
      final event = MatrixEvent.fromJson(
        const {
          'event_id': '\$1',
          'sender': '@u:t',
          'type': 'm.room.member',
          'origin_server_ts': 0,
          'content': {'membership': 'join', 'displayname': 'After'},
          'unsigned': {
            'prev_content': {'membership': 'join', 'displayname': 'Before'},
          },
        },
        roomId: '!r:t',
      );
      expect(event.prevContent, isNotNull);
      expect(event.prevContent!['membership'], 'join');
      expect(event.isMemberJoin, isFalse);
    });
  });
}
