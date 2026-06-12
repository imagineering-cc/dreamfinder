import 'dart:convert';

import 'package:dreamfinder/src/agent/tool_registry.dart';
import 'package:dreamfinder/src/matrix/matrix_client.dart';
import 'package:dreamfinder/src/tools/messaging_tools.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

/// Creates a mock HTTP client that responds based on the request path.
///
/// Handlers are checked in insertion order with `contains` matching, so put
/// more specific keys first (e.g. `joined_members` before `join`).
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

// Distinctive room localparts so handlers can route on substring regardless
// of percent-encoding of `!` and `:` in URLs. The Telegram/Discord rooms
// avoid 'mgmtroom' as a substring so handler keys stay unambiguous.
const _mgmtRoom = '!mgmtroom:test';
const _tgMgmtRoom = '!tgbridge:test';
const _dcMgmtRoom = '!dcbridge:test';
const _portalRoom = '!portalroom:test';

/// A bridge reply event carrying the portal permalink, as mautrix sends it
/// (URL-encoded room ID inside an HTML anchor, with via params).
Map<String, dynamic> _bridgeReplyEvent() => {
      'event_id': r'$bridgereply',
      'sender': '@whatsappbot:test',
      'type': 'm.room.message',
      'origin_server_ts': 2,
      'content': {
        'msgtype': 'm.notice',
        'body': 'Created portal room with +61400000000: !portalroom:test',
        'format': 'org.matrix.custom.html',
        'formatted_body': 'Created portal room with +61400000000: '
            '<a href="https://matrix.to/#/%21portalroom%3Atest?via=test">'
            'portal</a>',
      },
    };

Map<String, dynamic> _commandEvent() => {
      'event_id': r'$cmd1',
      'sender': '@river:test',
      'type': 'm.room.message',
      'origin_server_ts': 1,
      'content': {'msgtype': 'm.text', 'body': 'start-chat +61400000000'},
    };

ToolRegistry _makeRegistry(
  MatrixClient matrixClient, {
  required bool isAdmin,
  Duration timeout = const Duration(milliseconds: 200),
  String? telegramRoom,
  String? discordRoom,
}) {
  final registry = ToolRegistry();
  registry.setContext(ToolContext(
    senderId: '@nick:test',
    isAdmin: isAdmin,
    chatId: '!somewhere:test',
  ));
  registerMessagingTools(
    registry,
    matrixClient,
    whatsappManagementRoom: _mgmtRoom,
    telegramManagementRoom: telegramRoom,
    discordManagementRoom: discordRoom,
    bridgeBotIds: const {'@whatsappbot:test', '@telegrambot:test'},
    replyPollInterval: const Duration(milliseconds: 10),
    replyTimeout: timeout,
  );
  return registry;
}

void main() {
  const homeserver = 'https://matrix.test';
  const token = 'test-token';

  group('start_private_chat', () {
    test('is not registered without a management room', () {
      final registry = ToolRegistry();
      registerMessagingTools(
        registry,
        MatrixClient(homeserver: homeserver, accessToken: token),
        bridgeBotIds: const {'@whatsappbot:test'},
      );
      final names =
          registry.getAllToolDefinitions().map((t) => t.name).toList();
      expect(names, contains('dm_user'));
      expect(names, isNot(contains('start_private_chat')));
    });

    test('is not registered without bridge bot IDs', () {
      // The bridge bot identity authenticates the bridge's reply — without
      // it the tool would accept a permalink from any room member, so it
      // must refuse to register.
      final registry = ToolRegistry();
      registerMessagingTools(
        registry,
        MatrixClient(homeserver: homeserver, accessToken: token),
        whatsappManagementRoom: _mgmtRoom,
      );
      final names =
          registry.getAllToolDefinitions().map((t) => t.name).toList();
      expect(names, isNot(contains('start_private_chat')));
    });

    test('rejects non-admin callers', () async {
      final client = MatrixClient(
        homeserver: homeserver,
        accessToken: token,
        client: _mockClient({}),
      );
      final registry = _makeRegistry(client, isAdmin: false);

      final result = await registry.executeTool('start_private_chat', {
        'platform': 'whatsapp',
        'identifier': '+61400000000',
        'message': 'hi',
      });
      final json = jsonDecode(result) as Map<String, dynamic>;
      expect(json['error'], contains('admin'));
    });

    test('rejects malformed phone numbers without touching the bridge',
        () async {
      var sends = 0;
      final client = MatrixClient(
        homeserver: homeserver,
        accessToken: token,
        client: _mockClient({
          'send': (_) {
            sends++;
            return _jsonResponse({'event_id': r'$x'});
          },
        }),
      );
      final registry = _makeRegistry(client, isAdmin: true);

      for (final bad in [
        'nick',
        '@nick:test',
        '12345',
        '+1 (800) FLOWERS',
        '61400000000', // no leading + — ambiguous local format
        '+0400000000', // leading zero after +
      ]) {
        final result = await registry.executeTool('start_private_chat', {
          'platform': 'whatsapp',
          'identifier': bad,
          'message': 'hi',
        });
        final json = jsonDecode(result) as Map<String, dynamic>;
        expect(json['error'], contains('international'),
            reason: '"$bad" must be rejected');
      }
      expect(sends, 0, reason: 'no bridge command for invalid input');
    });

    test('returns structured errors for non-string args (no TypeError)',
        () async {
      // args come from model-generated JSON — a malformed call must come
      // back as a structured error, not a thrown TypeError.
      final client = MatrixClient(
        homeserver: homeserver,
        accessToken: token,
        client: _mockClient({}),
      );
      final registry = _makeRegistry(client, isAdmin: true);

      final badPhone = await registry.executeTool('start_private_chat', {
        'platform': 'whatsapp',
        'identifier': 61400000000, // int, not String
        'message': 'hi',
      });
      expect(
        (jsonDecode(badPhone) as Map<String, dynamic>)['error'],
        contains('international'),
      );

      final badMessage = await registry.executeTool('start_private_chat', {
        'platform': 'whatsapp',
        'identifier': '+61400000000',
        'message': <String>['not', 'a', 'string'],
      });
      expect(
        (jsonDecode(badMessage) as Map<String, dynamic>)['error'],
        contains('message'),
      );
    });

    test('full happy path: command → bridge reply → join → send', () async {
      final sentMessages = <String, List<String>>{};
      var joinedRoom = '';

      final client = MatrixClient(
        homeserver: homeserver,
        accessToken: token,
        client: _mockClient({
          'whoami': (_) => _jsonResponse({'user_id': '@river:test'}),
          'messages': (_) => _jsonResponse({
                'chunk': [_bridgeReplyEvent(), _commandEvent()],
              }),
          // NOTE: 'join' must come before room-localpart keys — the join
          // path contains the portal room ID too.
          'join': (req) {
            joinedRoom = Uri.decodeComponent(req.url.pathSegments.last);
            return _jsonResponse({'room_id': _portalRoom});
          },
          'mgmtroom': (req) {
            final body = jsonDecode(req.body) as Map<String, dynamic>;
            sentMessages.putIfAbsent(_mgmtRoom, () => []).add(
                  body['body'] as String,
                );
            return _jsonResponse({'event_id': r'$cmd1'});
          },
          'portalroom': (req) {
            final body = jsonDecode(req.body) as Map<String, dynamic>;
            sentMessages.putIfAbsent(_portalRoom, () => []).add(
                  body['body'] as String,
                );
            return _jsonResponse({'event_id': r'$opener'});
          },
        }),
      );
      final registry = _makeRegistry(client, isAdmin: true);

      final result = await registry.executeTool('start_private_chat', {
        'platform': 'whatsapp',
        // Spaces are tolerated and normalized away.
        'identifier': '+61 400 000 000',
        'message': 'Welcome to Imagineering!',
      });
      final json = jsonDecode(result) as Map<String, dynamic>;

      expect(json['ok'], isTrue, reason: 'got: $result');
      expect(json['portal_room_id'], _portalRoom);
      expect(sentMessages[_mgmtRoom], ['start-chat +61400000000']);
      expect(joinedRoom, _portalRoom);
      expect(sentMessages[_portalRoom], ['Welcome to Imagineering!']);
    });

    test('surfaces the bridge error text when no portal link arrives',
        () async {
      final client = MatrixClient(
        homeserver: homeserver,
        accessToken: token,
        client: _mockClient({
          'whoami': (_) => _jsonResponse({'user_id': '@river:test'}),
          'messages': (_) => _jsonResponse({
                'chunk': [
                  {
                    'event_id': r'$err',
                    'sender': '@whatsappbot:test',
                    'type': 'm.room.message',
                    'origin_server_ts': 2,
                    'content': {
                      'msgtype': 'm.notice',
                      'body': 'The server said +61400000000 is not on WhatsApp',
                    },
                  },
                  _commandEvent(),
                ],
              }),
          'mgmtroom': (_) => _jsonResponse({'event_id': r'$cmd1'}),
        }),
      );
      final registry = _makeRegistry(
        client,
        isAdmin: true,
        timeout: const Duration(milliseconds: 50),
      );

      final result = await registry.executeTool('start_private_chat', {
        'platform': 'whatsapp',
        'identifier': '+61400000000',
        'message': 'hi',
      });
      final json = jsonDecode(result) as Map<String, dynamic>;
      expect(json['error'], contains('not on WhatsApp'));
    });

    test('times out cleanly when the bridge never replies', () async {
      final client = MatrixClient(
        homeserver: homeserver,
        accessToken: token,
        client: _mockClient({
          'whoami': (_) => _jsonResponse({'user_id': '@river:test'}),
          // Only our own command is visible — no bridge reply ever.
          'messages': (_) => _jsonResponse({
                'chunk': [_commandEvent()],
              }),
          'mgmtroom': (_) => _jsonResponse({'event_id': r'$cmd1'}),
        }),
      );
      final registry = _makeRegistry(
        client,
        isAdmin: true,
        timeout: const Duration(milliseconds: 50),
      );

      final result = await registry.executeTool('start_private_chat', {
        'platform': 'whatsapp',
        'identifier': '+61400000000',
        'message': 'hi',
      });
      final json = jsonDecode(result) as Map<String, dynamic>;
      expect(json['error'], contains('Timed out'));
    });

    test('ignores permalinks from senders that are not the bridge bot',
        () async {
      // Trust model: only the bridge bot's replies may name the portal.
      // A permalink posted by anyone else in the management room must not
      // be able to redirect the opener to an attacker-chosen room.
      final impostorReply = {
        'event_id': r'$impostor',
        'sender': '@mallory:test',
        'type': 'm.room.message',
        'origin_server_ts': 2,
        'content': {
          'msgtype': 'm.text',
          'body': 'here is your chat',
          'format': 'org.matrix.custom.html',
          'formatted_body':
              '<a href="https://matrix.to/#/%21evilroom%3Atest">chat</a>',
        },
      };
      final client = MatrixClient(
        homeserver: homeserver,
        accessToken: token,
        client: _mockClient({
          'whoami': (_) => _jsonResponse({'user_id': '@river:test'}),
          'messages': (_) => _jsonResponse({
                'chunk': [impostorReply, _commandEvent()],
              }),
          'mgmtroom': (_) => _jsonResponse({'event_id': r'$cmd1'}),
        }),
      );
      final registry = _makeRegistry(
        client,
        isAdmin: true,
        timeout: const Duration(milliseconds: 50),
      );

      final result = await registry.executeTool('start_private_chat', {
        'platform': 'whatsapp',
        'identifier': '+61400000000',
        'message': 'hi',
      });
      final json = jsonDecode(result) as Map<String, dynamic>;
      expect(json['error'], contains('Timed out'),
          reason: 'a non-bridge sender\'s permalink must be ignored');
    });

    test('surfaces a join failure with join context instead of sending',
        () async {
      var portalSends = 0;
      final client = MatrixClient(
        homeserver: homeserver,
        accessToken: token,
        client: _mockClient({
          'whoami': (_) => _jsonResponse({'user_id': '@river:test'}),
          'messages': (_) => _jsonResponse({
                'chunk': [_bridgeReplyEvent(), _commandEvent()],
              }),
          'join': (_) => http.Response('{"errcode":"M_FORBIDDEN"}', 403),
          'mgmtroom': (_) => _jsonResponse({'event_id': r'$cmd1'}),
          'portalroom': (_) {
            portalSends++;
            return _jsonResponse({'event_id': r'$opener'});
          },
        }),
      );
      final registry = _makeRegistry(client, isAdmin: true);

      final result = await registry.executeTool('start_private_chat', {
        'platform': 'whatsapp',
        'identifier': '+61400000000',
        'message': 'hi',
      });
      final json = jsonDecode(result) as Map<String, dynamic>;
      expect(json['error'], contains('joining it failed'));
      expect(portalSends, 0,
          reason: 'a failed join must not be masked by a send attempt');
    });

    test('ignores stale bridge messages older than the command', () async {
      // A permalink from a PREVIOUS start-chat sits in the room history,
      // BELOW (older than) our command. It must not be picked up: the scan
      // stops at the command event.
      final staleReply = {
        'event_id': r'$stale',
        'sender': '@whatsappbot:test',
        'type': 'm.room.message',
        'origin_server_ts': 0,
        'content': {
          'msgtype': 'm.notice',
          'body': 'old link',
          'format': 'org.matrix.custom.html',
          'formatted_body':
              '<a href="https://matrix.to/#/%21wrongportal%3Atest">old</a>',
        },
      };
      final client = MatrixClient(
        homeserver: homeserver,
        accessToken: token,
        client: _mockClient({
          'whoami': (_) => _jsonResponse({'user_id': '@river:test'}),
          'messages': (_) => _jsonResponse({
                // Newest-first: command, THEN the stale reply.
                'chunk': [_commandEvent(), staleReply],
              }),
          'mgmtroom': (_) => _jsonResponse({'event_id': r'$cmd1'}),
        }),
      );
      final registry = _makeRegistry(
        client,
        isAdmin: true,
        timeout: const Duration(milliseconds: 50),
      );

      final result = await registry.executeTool('start_private_chat', {
        'platform': 'whatsapp',
        'identifier': '+61400000000',
        'message': 'hi',
      });
      final json = jsonDecode(result) as Map<String, dynamic>;
      expect(json['error'], contains('Timed out'),
          reason: 'stale permalink below the command must not match');
    });
  });

  group('start_private_chat platforms', () {
    test('platform enum lists exactly the configured platforms', () {
      final client = MatrixClient(
        homeserver: homeserver,
        accessToken: token,
        client: _mockClient({}),
      );
      // WhatsApp + Telegram configured; Signal/Discord not.
      final registry = _makeRegistry(
        client,
        isAdmin: true,
        telegramRoom: _tgMgmtRoom,
      );
      final tool = registry
          .getAllToolDefinitions()
          .singleWhere((t) => t.name == 'start_private_chat');
      final schema = tool.inputSchema as Map<String, dynamic>;
      final properties = schema['properties'] as Map<String, dynamic>;
      final platform = properties['platform'] as Map<String, dynamic>;
      expect(platform['enum'], unorderedEquals(['whatsapp', 'telegram']),
          reason: 'unconfigured platforms must not be offered to the model');
    });

    test('rejects a platform whose bridge is not configured', () async {
      final client = MatrixClient(
        homeserver: homeserver,
        accessToken: token,
        client: _mockClient({}),
      );
      final registry = _makeRegistry(client, isAdmin: true);

      final result = await registry.executeTool('start_private_chat', {
        'platform': 'signal',
        'identifier': '+61400000000',
        'message': 'hi',
      });
      final json = jsonDecode(result) as Map<String, dynamic>;
      expect(json['error'], contains('platform must be one of'));
      expect(json['error'], contains('whatsapp'),
          reason: 'the error should name what IS available');
    });

    test('telegram full happy path drives the telegram management room',
        () async {
      final sentMessages = <String, List<String>>{};
      var joinedRoom = '';
      final tgBridgeReply = {
        'event_id': r'$tgreply',
        'sender': '@telegrambot:test',
        'type': 'm.room.message',
        'origin_server_ts': 2,
        'content': {
          'msgtype': 'm.notice',
          'body': 'Created portal room: !portalroom:test',
          'format': 'org.matrix.custom.html',
          'formatted_body':
              '<a href="https://matrix.to/#/%21portalroom%3Atest?via=test">'
                  'portal</a>',
        },
      };
      final client = MatrixClient(
        homeserver: homeserver,
        accessToken: token,
        client: _mockClient({
          'whoami': (_) => _jsonResponse({'user_id': '@river:test'}),
          'messages': (_) => _jsonResponse({
                'chunk': [tgBridgeReply, _commandEvent()],
              }),
          'join': (req) {
            joinedRoom = Uri.decodeComponent(req.url.pathSegments.last);
            return _jsonResponse({'room_id': _portalRoom});
          },
          'tgbridge': (req) {
            final body = jsonDecode(req.body) as Map<String, dynamic>;
            sentMessages.putIfAbsent(_tgMgmtRoom, () => []).add(
                  body['body'] as String,
                );
            return _jsonResponse({'event_id': r'$cmd1'});
          },
          'portalroom': (req) {
            final body = jsonDecode(req.body) as Map<String, dynamic>;
            sentMessages.putIfAbsent(_portalRoom, () => []).add(
                  body['body'] as String,
                );
            return _jsonResponse({'event_id': r'$opener'});
          },
        }),
      );
      final registry = _makeRegistry(
        client,
        isAdmin: true,
        telegramRoom: _tgMgmtRoom,
      );

      final result = await registry.executeTool('start_private_chat', {
        'platform': 'telegram',
        'identifier': '+61 461 488 770',
        'message': 'Yo from River!',
      });
      final json = jsonDecode(result) as Map<String, dynamic>;

      expect(json['ok'], isTrue, reason: 'got: $result');
      expect(json['platform'], 'telegram');
      expect(json['portal_room_id'], _portalRoom);
      // The command must land in the TELEGRAM management room — the
      // regression that matters most in a multi-platform refactor.
      expect(sentMessages[_tgMgmtRoom], ['start-chat +61461488770']);
      expect(sentMessages.containsKey(_mgmtRoom), isFalse,
          reason: 'the WhatsApp management room must not be touched');
      expect(joinedRoom, _portalRoom);
      expect(sentMessages[_portalRoom], ['Yo from River!']);
    });

    test('cross-bridge reply is NOT trusted (per-platform bot sets)', () async {
      // Trust model: a WHATSAPP bridge bot's permalink posted in the
      // TELEGRAM management room must not name the portal — each platform
      // trusts only its own bridge bot, even though both bots are in the
      // flat BRIDGE_BOT_IDS config.
      final crossBridgeReply = {
        'event_id': r'$crossreply',
        'sender': '@whatsappbot:test', // wrong bridge for telegram
        'type': 'm.room.message',
        'origin_server_ts': 2,
        'content': {
          'msgtype': 'm.notice',
          'body': 'Created portal room',
          'format': 'org.matrix.custom.html',
          'formatted_body':
              '<a href="https://matrix.to/#/%21portalroom%3Atest">portal</a>',
        },
      };
      final client = MatrixClient(
        homeserver: homeserver,
        accessToken: token,
        client: _mockClient({
          'whoami': (_) => _jsonResponse({'user_id': '@river:test'}),
          'messages': (_) => _jsonResponse({
                'chunk': [crossBridgeReply, _commandEvent()],
              }),
          'tgbridge': (_) => _jsonResponse({'event_id': r'$cmd1'}),
        }),
      );
      final registry = _makeRegistry(
        client,
        isAdmin: true,
        telegramRoom: _tgMgmtRoom,
        timeout: const Duration(milliseconds: 50),
      );
      final result = await registry.executeTool('start_private_chat', {
        'platform': 'telegram',
        'identifier': '+61400000000',
        'message': 'hi',
      });
      final json = jsonDecode(result) as Map<String, dynamic>;
      expect(json['error'], contains('Timed out'),
          reason: 'another bridge\'s bot must not be able to name the portal');
    });

    test('signal appears in the platform enum when configured', () {
      final client = MatrixClient(
        homeserver: homeserver,
        accessToken: token,
        client: _mockClient({}),
      );
      final registry = ToolRegistry();
      registry.setContext(ToolContext(
        senderId: '@nick:test',
        isAdmin: true,
        chatId: '!somewhere:test',
      ));
      registerMessagingTools(
        registry,
        client,
        signalManagementRoom: '!sigbridge:test',
        bridgeBotIds: const {'@signalbot:test'},
      );
      final tool = registry
          .getAllToolDefinitions()
          .singleWhere((t) => t.name == 'start_private_chat');
      final schema = tool.inputSchema as Map<String, dynamic>;
      final properties = schema['properties'] as Map<String, dynamic>;
      final platform = properties['platform'] as Map<String, dynamic>;
      expect(platform['enum'], ['signal']);
    });

    test('discord full happy path drives the discord management room',
        () async {
      final sentMessages = <String, List<String>>{};
      final dcBridgeReply = {
        'event_id': r'$dcreply',
        'sender': '@discordbot:test',
        'type': 'm.room.message',
        'origin_server_ts': 2,
        'content': {
          'msgtype': 'm.notice',
          'body': 'Created portal room',
          'format': 'org.matrix.custom.html',
          'formatted_body':
              '<a href="https://matrix.to/#/%21portalroom%3Atest">portal</a>',
        },
      };
      final client = MatrixClient(
        homeserver: homeserver,
        accessToken: token,
        client: _mockClient({
          'whoami': (_) => _jsonResponse({'user_id': '@river:test'}),
          'messages': (_) => _jsonResponse({
                'chunk': [dcBridgeReply, _commandEvent()],
              }),
          'join': (_) => _jsonResponse({'room_id': _portalRoom}),
          'dcbridge': (req) {
            final body = jsonDecode(req.body) as Map<String, dynamic>;
            sentMessages.putIfAbsent(_dcMgmtRoom, () => []).add(
                  body['body'] as String,
                );
            return _jsonResponse({'event_id': r'$cmd1'});
          },
          'portalroom': (req) {
            final body = jsonDecode(req.body) as Map<String, dynamic>;
            sentMessages.putIfAbsent(_portalRoom, () => []).add(
                  body['body'] as String,
                );
            return _jsonResponse({'event_id': r'$opener'});
          },
        }),
      );
      final registry = ToolRegistry();
      registry.setContext(ToolContext(
        senderId: '@nick:test',
        isAdmin: true,
        chatId: '!somewhere:test',
      ));
      registerMessagingTools(
        registry,
        client,
        discordManagementRoom: _dcMgmtRoom,
        bridgeBotIds: const {'@discordbot:test'},
        replyPollInterval: const Duration(milliseconds: 10),
        replyTimeout: const Duration(milliseconds: 200),
      );

      // Leading @ is stripped; both snowflake and username shapes accepted.
      final result = await registry.executeTool('start_private_chat', {
        'platform': 'discord',
        'identifier': '@some.username',
        'message': 'Yo from River!',
      });
      final json = jsonDecode(result) as Map<String, dynamic>;
      expect(json['ok'], isTrue, reason: 'got: $result');
      expect(sentMessages[_dcMgmtRoom], ['start-chat some.username']);
      expect(sentMessages[_portalRoom], ['Yo from River!']);
    });

    test('discord identifiers are validated per platform', () async {
      var sends = 0;
      final client = MatrixClient(
        homeserver: homeserver,
        accessToken: token,
        client: _mockClient({
          'send': (_) {
            sends++;
            return _jsonResponse({'event_id': r'$x'});
          },
        }),
      );
      final registry = _makeRegistry(
        client,
        isAdmin: true,
        discordRoom: _dcMgmtRoom,
      );

      for (final bad in [
        'Bad Name!',
        'a',
        '+61400000000',
        'UPPER',
        '.abc', // leading dot — Discord rejects
        'abc.', // trailing dot
        'a..b', // consecutive dots
      ]) {
        final result = await registry.executeTool('start_private_chat', {
          'platform': 'discord',
          'identifier': bad,
          'message': 'hi',
        });
        final json = jsonDecode(result) as Map<String, dynamic>;
        expect(json['error'], contains('Discord'),
            reason: '"$bad" must be rejected for discord');
      }
      // And a phone-platform identifier must not accept a discord username.
      final crossed = await registry.executeTool('start_private_chat', {
        'platform': 'whatsapp',
        'identifier': 'some.username',
        'message': 'hi',
      });
      expect(
        (jsonDecode(crossed) as Map<String, dynamic>)['error'],
        contains('international'),
      );
      expect(sends, 0, reason: 'no bridge command for invalid input');
    });
  });

  group('dm_user', () {
    test('still registered and admin-gated', () async {
      final client = MatrixClient(
        homeserver: homeserver,
        accessToken: token,
        client: _mockClient({}),
      );
      final registry = _makeRegistry(client, isAdmin: false);
      final result = await registry.executeTool('dm_user', {
        'user_id': '@alice:test',
        'message': 'hi',
      });
      final json = jsonDecode(result) as Map<String, dynamic>;
      expect(json['error'], contains('admin'));
    });
  });
}
