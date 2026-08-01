import 'package:dreamfinder/src/bot/welcome.dart';
import 'package:test/test.dart';

void main() {
  const hub = '!hub:imagineering.cc';
  final hubs = {hub};
  const human = '@alice:imagineering.cc';
  // A bridged community member — a REAL person, carrying the appservice
  // namespace. Must be welcomed, never filtered (verified against prod).
  const bridgedHuman = '@signal_1f11a469-eb2d-4c50-a4aa-775e781e8911'
      ':imagineering.cc';

  group('isNonHumanMember', () {
    test('flags relay puppets, bridge bots and self — the true non-humans', () {
      expect(isNonHumanMember('@_relay_signal_abc:imagineering.cc'), isTrue);
      expect(isNonHumanMember('@signalbot:imagineering.cc'), isTrue);
      expect(isNonHumanMember('@whatsappbot:imagineering.cc'), isTrue);
      expect(isNonHumanMember('@dreamfinder-bot:imagineering.cc'), isTrue);
    });

    test('does NOT flag bridged community members (they are people)', () {
      expect(isNonHumanMember(bridgedHuman), isFalse);
      expect(
          isNonHumanMember('@whatsapp_61400000000:imagineering.cc'), isFalse);
      expect(isNonHumanMember('@telegram_12345:imagineering.cc'), isFalse);
    });

    test('flags explicit bridge bots and self puppets via params', () {
      expect(
        isNonHumanMember('@custombot:imagineering.cc',
            bridgeBotIds: {'@custombot:imagineering.cc'}),
        isTrue,
      );
      expect(
        isNonHumanMember('@_relay_x:imagineering.cc',
            selfPuppetIds: ['@_relay_x:imagineering.cc']),
        isTrue,
      );
    });

    test('does not flag a real homeserver user', () {
      expect(isNonHumanMember(human), isFalse);
    });

    test('operator prefixes ADD to the defaults, never replace them', () {
      // The call site builds [...defaults, ...operator] — mirror that here.
      final merged = [...nonHumanMxidPrefixes, '@gmessages_'];
      // The operator-added namespace is filtered.
      expect(
        isNonHumanMember('@gmessages_1:imagineering.cc', prefixes: merged),
        isTrue,
      );
      // AND the built-in defaults still filter — adding one prefix must not
      // silently disable @signalbot etc. (the fail-open footgun).
      expect(
        isNonHumanMember('@signalbot:imagineering.cc', prefixes: merged),
        isTrue,
      );
      // A bridged human is still not filtered under the merged list.
      expect(isNonHumanMember(bridgedHuman, prefixes: merged), isFalse);
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

    test('welcomes a bridged community member (@signal_ is a person)', () {
      final msg = welcomeMessage(
        sender: bridgedHuman,
        roomId: hub,
        isMemberJoin: true,
        hubRoomIds: hubs,
        displayName: 'Rob Bob',
      );
      expect(msg, contains('Welcome Rob Bob'));
    });

    test('welcomes an unresolved-name member once, with the name as-is', () {
      // "pvt pvt" is a bridged human whose name has not resolved — Nick's
      // call: welcome once with whatever name; dedup makes it one-time.
      final msg = welcomeMessage(
        sender: bridgedHuman,
        roomId: hub,
        isMemberJoin: true,
        hubRoomIds: hubs,
        displayName: 'pvt pvt',
      );
      expect(msg, contains('Welcome pvt pvt'));
    });

    test('never welcomes a bridge bot / relay puppet', () {
      for (final nonHuman in [
        '@signalbot:imagineering.cc',
        '@_relay_signal_x:imagineering.cc',
        '@dreamfinder-bot:imagineering.cc',
      ]) {
        expect(
          welcomeMessage(
            sender: nonHuman,
            roomId: hub,
            isMemberJoin: true,
            hubRoomIds: hubs,
            displayName: 'whatever',
          ),
          isNull,
          reason: '$nonHuman is not a person',
        );
      }
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
        alreadyWelcomed: () => true,
      );
      expect(msg, isNull);
    });

    test('does not consult the dedup store until join/hub/non-bot gates pass',
        () {
      var thunkCalls = 0;
      bool countingThunk() {
        thunkCalls++;
        return false;
      }

      // Non-hub room: rejected before the thunk.
      welcomeMessage(
        sender: human,
        roomId: '!portal:imagineering.cc',
        isMemberJoin: true,
        hubRoomIds: hubs,
        alreadyWelcomed: countingThunk,
      );
      // Bridge bot: rejected before the thunk.
      welcomeMessage(
        sender: '@signalbot:imagineering.cc',
        roomId: hub,
        isMemberJoin: true,
        hubRoomIds: hubs,
        alreadyWelcomed: countingThunk,
      );
      expect(thunkCalls, 0);

      // Real human in hub: the thunk IS consulted.
      welcomeMessage(
        sender: human,
        roomId: hub,
        isMemberJoin: true,
        hubRoomIds: hubs,
        alreadyWelcomed: countingThunk,
      );
      expect(thunkCalls, 1);
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

    test('sanitizes newlines / control / bidi chars in display name', () {
      // 'Ali' + newline + 'ce' + U+202E (RTL override) + double space + 'evil'.
      final evilName = 'Ali\nce${String.fromCharCode(0x202e)}  evil';
      final msg = welcomeMessage(
        sender: human,
        roomId: hub,
        isMemberJoin: true,
        hubRoomIds: hubs,
        displayName: evilName,
      );
      expect(msg, isNotNull);
      expect(
        msg!.runes.any((r) =>
            r < 0x20 ||
            r == 0x7f ||
            (r >= 0x80 && r <= 0x9f) ||
            (r >= 0x202a && r <= 0x202e)),
        isFalse,
      );
      expect(msg, contains('Welcome Ali ce evil'));
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
