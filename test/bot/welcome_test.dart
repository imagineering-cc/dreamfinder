import 'package:dreamfinder/src/bot/welcome.dart';
import 'package:test/test.dart';

void main() {
  const hub = '!hub:imagineering.cc';
  final hubs = {hub};
  const human = '@alice:imagineering.cc';

  group('isBridgePuppet', () {
    test('flags appservice namespace puppets', () {
      expect(isBridgePuppet('@whatsapp_61400000000:imagineering.cc'), isTrue);
      expect(isBridgePuppet('@_relay_signal_abc:imagineering.cc'), isTrue);
      expect(isBridgePuppet('@telegram_12345:imagineering.cc'), isTrue);
    });

    test('flags explicit bridge bots and self puppets', () {
      expect(
        isBridgePuppet('@whatsappbot:imagineering.cc',
            bridgeBotIds: {'@whatsappbot:imagineering.cc'}),
        isTrue,
      );
      expect(
        isBridgePuppet('@_relay_x:imagineering.cc',
            selfPuppetIds: ['@_relay_x:imagineering.cc']),
        isTrue,
      );
    });

    test('does not flag a real homeserver user', () {
      expect(isBridgePuppet(human), isFalse);
    });
  });

  group('welcomeMessage', () {
    test('welcomes a real human joining the hub', () {
      final msg = welcomeMessage(
        sender: human,
        roomId: hub,
        isMemberJoin: true,
        hubRoomIds: hubs,
        displayName: 'Alice',
      );
      expect(msg, contains('Welcome Alice'));
      expect(msg, contains('kickstart'));
    });

    test('never welcomes a bridge puppet — the "pvt pvt" regression', () {
      final msg = welcomeMessage(
        sender: '@whatsapp_61400000000:imagineering.cc',
        roomId: hub,
        isMemberJoin: true,
        hubRoomIds: hubs,
        displayName: 'pvt pvt',
      );
      expect(msg, isNull);
    });

    test('stays silent outside hub rooms (portal churn)', () {
      final msg = welcomeMessage(
        sender: human,
        roomId: '!portal:imagineering.cc',
        isMemberJoin: true,
        hubRoomIds: hubs,
        displayName: 'Alice',
      );
      expect(msg, isNull);
    });

    test('does not welcome the same person twice (resync dedup)', () {
      final msg = welcomeMessage(
        sender: human,
        roomId: hub,
        isMemberJoin: true,
        hubRoomIds: hubs,
        displayName: 'Alice',
        alreadyWelcomed: true,
      );
      expect(msg, isNull);
    });

    test('ignores non-join membership events (profile updates)', () {
      final msg = welcomeMessage(
        sender: human,
        roomId: hub,
        isMemberJoin: false,
        hubRoomIds: hubs,
        displayName: 'Alice',
      );
      expect(msg, isNull);
    });

    test('falls back to MXID localpart when displayName is blank', () {
      final msg = welcomeMessage(
        sender: human,
        roomId: hub,
        isMemberJoin: true,
        hubRoomIds: hubs,
        displayName: '   ',
      );
      expect(msg, contains('Welcome alice'));
    });

    test('does not throw on empty or malformed sender (untrusted boundary)',
        () {
      for (final bad in ['', '@', 'alice:server', 'no-at-sign']) {
        expect(
          () => welcomeMessage(
            sender: bad,
            roomId: hub,
            isMemberJoin: true,
            hubRoomIds: hubs,
          ),
          returnsNormally,
          reason: 'sender "$bad" must not RangeError the sync loop',
        );
      }
    });

    test('caps an absurdly long display name', () {
      final msg = welcomeMessage(
        sender: human,
        roomId: hub,
        isMemberJoin: true,
        hubRoomIds: hubs,
        displayName: 'A' * 5000,
      );
      expect(msg!.length, lessThan(200));
      expect(msg, contains('…'));
    });

    test('filters a sender in bridgeBotIds / selfPuppetIds via welcomeMessage',
        () {
      expect(
        welcomeMessage(
          sender: '@whatsappbot:imagineering.cc',
          roomId: hub,
          isMemberJoin: true,
          hubRoomIds: hubs,
          bridgeBotIds: {'@whatsappbot:imagineering.cc'},
        ),
        isNull,
      );
      expect(
        welcomeMessage(
          sender: '@relayed:imagineering.cc',
          roomId: hub,
          isMemberJoin: true,
          hubRoomIds: hubs,
          selfPuppetIds: ['@relayed:imagineering.cc'],
        ),
        isNull,
      );
    });

    test('empty hubRoomIds silences all welcomes', () {
      expect(
        welcomeMessage(
          sender: human,
          roomId: hub,
          isMemberJoin: true,
          hubRoomIds: const {},
          displayName: 'Alice',
        ),
        isNull,
      );
    });
  });

  test('welcomeDedupKey is per room and sender', () {
    expect(welcomeDedupKey(hub, human), 'welcomed::$hub::$human');
  });
}
