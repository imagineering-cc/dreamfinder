import 'package:dreamfinder/src/matrix/participant.dart';
import 'package:test/test.dart';

void main() {
  // Seeded from the REAL prod mautrix registrations (verified 2026-08-10):
  // each bridge exposes `@<id>bot:` (the bot) + `@<id>_.*` (puppets = people).
  final classifier = ParticipantClassifier(
    botUserId: '@dreamfinder-bot:imagineering.cc',
    selfPuppetIds: const {'@_relay_river:imagineering.cc'},
    bridgeBotIds: const {'@custombot:imagineering.cc'},
  );

  group('ParticipantClassifier.classify', () {
    test('bridged community members are HUMAN (the welcome-nobody bug)', () {
      // The catastrophe class: @<platform>_<uuid> puppets are real people.
      expect(classifier.classify('@signal_abc-123:imagineering.cc'),
          ParticipantKind.human);
      expect(classifier.classify('@whatsapp_61400000000:imagineering.cc'),
          ParticipantKind.human);
      expect(classifier.classify('@telegram_12345:imagineering.cc'),
          ParticipantKind.human);
      expect(classifier.classify('@discord_999:imagineering.cc'),
          ParticipantKind.human);
    });

    test('native Matrix users are HUMAN', () {
      expect(
          classifier.classify('@alice:imagineering.cc'), ParticipantKind.human);
      // A localpart that merely CONTAINS an underscore is not a puppet.
      expect(classifier.classify('@bob_smith:imagineering.cc'),
          ParticipantKind.human);
    });

    test('mautrix bridge bots are BRIDGE_BOT', () {
      for (final bot in [
        '@signalbot:imagineering.cc',
        '@whatsappbot:imagineering.cc',
        '@telegrambot:imagineering.cc',
        '@discordbot:imagineering.cc',
      ]) {
        expect(classifier.classify(bot), ParticipantKind.bridgeBot,
            reason: bot);
      }
    });

    test('explicit bridgeBotIds are BRIDGE_BOT', () {
      expect(classifier.classify('@custombot:imagineering.cc'),
          ParticipantKind.bridgeBot);
    });

    test('superbridge relay puppets are RELAY_PUPPET', () {
      expect(classifier.classify('@_relay_someone:imagineering.cc'),
          ParticipantKind.relayPuppet);
    });

    test('the bot itself and its self-puppets are SELF', () {
      expect(classifier.classify('@dreamfinder-bot:imagineering.cc'),
          ParticipantKind.self);
      expect(classifier.classify('@_relay_river:imagineering.cc'),
          ParticipantKind.self);
    });

    test('SELF takes precedence over every other kind', () {
      // A self-puppet that ALSO matches the relay prefix must read as self,
      // never relayPuppet — otherwise River could respond to its own echo.
      final c = ParticipantClassifier(
        botUserId: '@dreamfinder-bot:imagineering.cc',
        selfPuppetIds: const {'@_relay_river:imagineering.cc'},
      );
      expect(c.classify('@_relay_river:imagineering.cc'), ParticipantKind.self);
    });

    test('malformed / non-MXID senders fail safe to HUMAN', () {
      // A bridge/homeserver can emit a malformed sender across an untrusted
      // boundary; it must not crash and must not be mistaken for self/bot.
      expect(classifier.classify(''), ParticipantKind.human);
      expect(classifier.classify('@'), ParticipantKind.human);
      expect(classifier.classify('not-an-mxid'), ParticipantKind.human);
    });

    test('an explicit self-puppet wins over its namespace kind', () {
      // River's OWN relayed puppets are configured by exact MXID and can sit in
      // the @telegram_ / @_relay_signal_ namespaces. Those specific ids are
      // self; OTHER ids in the same namespace are the community's people/relay
      // puppets — the self-echo drop must not swallow them (migrated from the
      // old env.isSelf coverage).
      final c = ParticipantClassifier(
        botUserId: '@dreamfinder-bot:imagineering.cc',
        selfPuppetIds: const {
          '@_relay_signal_8b12f8cf:imagineering.cc',
          '@telegram_8927028624:imagineering.cc',
        },
      );
      // River's own puppets → self.
      expect(c.classify('@_relay_signal_8b12f8cf:imagineering.cc'),
          ParticipantKind.self);
      expect(c.classify('@telegram_8927028624:imagineering.cc'),
          ParticipantKind.self);
      // A DIFFERENT id in the same namespaces is NOT self:
      //  - another @telegram_ is a bridged human,
      //  - another @_relay_signal_ is a (human's) relay puppet.
      expect(c.classify('@telegram_9c2dfb33:imagineering.cc'),
          ParticipantKind.human);
      expect(c.classify('@_relay_signal_9c2dfb33:imagineering.cc'),
          ParticipantKind.relayPuppet);
    });

    test('operator-added bot prefixes extend, never replace, the defaults', () {
      // The call site builds [...defaults, ...operator]; a new bridge bot can be
      // covered without a deploy, and adding one must not disable the built-ins.
      final c = ParticipantClassifier(
        botUserId: '@dreamfinder-bot:imagineering.cc',
        bridgeBotPrefixes: [...defaultBridgeBotPrefixes, '@gmessagesbot:'],
      );
      expect(c.classify('@gmessagesbot:imagineering.cc'),
          ParticipantKind.bridgeBot);
      expect(c.classify('@signalbot:imagineering.cc'),
          ParticipantKind.bridgeBot); // default still applies
      expect(c.classify('@signal_abc:imagineering.cc'),
          ParticipantKind.human); // a person is still a person
    });

    test('convenience predicates match the enum', () {
      expect(classifier.isSelf('@dreamfinder-bot:imagineering.cc'), isTrue);
      expect(classifier.isSelf('@alice:imagineering.cc'), isFalse);
      expect(classifier.isHuman('@signal_abc:imagineering.cc'), isTrue);
      expect(classifier.isHuman('@signalbot:imagineering.cc'), isFalse);
      expect(classifier.isBridgeBot('@signalbot:imagineering.cc'), isTrue);
    });
  });
}
