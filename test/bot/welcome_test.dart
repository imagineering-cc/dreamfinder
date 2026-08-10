import 'package:dreamfinder/src/bot/welcome.dart';
import 'package:dreamfinder/src/matrix/participant.dart';
import 'package:test/test.dart';

void main() {
  const hub = '!hub:imagineering.cc';
  final hubs = {hub};
  const human = '@alice:imagineering.cc';
  // A bridged community member — a REAL person, carrying the appservice
  // namespace. Must be welcomed, never filtered (verified against prod).
  const bridgedHuman = '@signal_1f11a469-eb2d-4c50-a4aa-775e781e8911'
      ':imagineering.cc';

  // The single classifier the welcome path consults. Who-is-a-person coverage
  // lives in test/matrix/participant_test.dart; here we only need a real one.
  final classifier = ParticipantClassifier(
    botUserId: '@dreamfinder-bot:imagineering.cc',
  );

  group('welcomeMessage', () {
    test('welcomes a real human joining the hub', () {
      final msg = welcomeMessage(
        sender: human,
        roomId: hub,
        isMemberJoin: true,
        hubRoomIds: hubs,
        classifier: classifier,
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
        classifier: classifier,
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
        classifier: classifier,
        displayName: 'pvt pvt',
      );
      expect(msg, contains('Welcome pvt pvt'));
    });

    test('never welcomes a bridge bot / relay puppet / self', () {
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
            classifier: classifier,
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
        classifier: classifier,
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
        classifier: classifier,
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
        classifier: classifier,
        alreadyWelcomed: countingThunk,
      );
      // Bridge bot: rejected before the thunk.
      welcomeMessage(
        sender: '@signalbot:imagineering.cc',
        roomId: hub,
        isMemberJoin: true,
        hubRoomIds: hubs,
        classifier: classifier,
        alreadyWelcomed: countingThunk,
      );
      expect(thunkCalls, 0);

      // Real human in hub: the thunk IS consulted.
      welcomeMessage(
        sender: human,
        roomId: hub,
        isMemberJoin: true,
        hubRoomIds: hubs,
        classifier: classifier,
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
        classifier: classifier,
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
        classifier: classifier,
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
            classifier: classifier,
          ),
          returnsNormally,
          reason: 'sender "$bad" must not RangeError the sync loop',
        );
      }
    });

    test('sanitizes the MXID fallback path too (blank displayName)', () {
      // Malformed sender with control chars, no displayname → fallback used.
      final msg = welcomeMessage(
        sender: '@a\nb${String.fromCharCode(0x202e)}c:imagineering.cc',
        roomId: hub,
        isMemberJoin: true,
        hubRoomIds: hubs,
        classifier: classifier,
        displayName: null,
      );
      expect(msg, isNotNull);
      expect(
        msg!.runes
            .any((r) => r < 0x20 || r == 0x7f || (r >= 0x202a && r <= 0x202e)),
        isFalse,
      );
    });

    test('caps an absurdly long display name', () {
      final msg = welcomeMessage(
        sender: human,
        roomId: hub,
        isMemberJoin: true,
        hubRoomIds: hubs,
        classifier: classifier,
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
        classifier: classifier,
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
          classifier: classifier,
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
