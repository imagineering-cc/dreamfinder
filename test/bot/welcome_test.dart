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
  });

  test('welcomeDedupKey is per room and sender', () {
    expect(welcomeDedupKey(hub, human), 'welcomed::$hub::$human');
  });
}
