import 'package:dreamfinder/src/config/env.dart';
import 'package:test/test.dart';

void main() {
  group('Env.forTesting', () {
    test('provides sensible defaults', () {
      final env = Env.forTesting();
      expect(env.anthropicApiKey, equals('test-key'));
      expect(env.matrixHomeserver, equals('https://matrix.test'));
      expect(env.matrixAccessToken, equals('test-token'));
      expect(env.botName, equals('Dreamfinder'));
      expect(env.databasePath, equals('./data/bot.db'));
      expect(env.logLevel, equals('info'));
    });

    test('allows overriding all fields', () {
      final env = Env.forTesting(
        anthropicApiKey: 'custom-key',
        matrixHomeserver: 'https://matrix.custom',
        matrixAccessToken: 'custom-token',
        matrixUsername: 'bot',
        matrixPassword: 'secret',
        matrixIgnoreRooms: ['!ignore:server'],
        kanBaseUrl: 'http://kan',
        kanApiKey: 'kan-key',
        outlineBaseUrl: 'http://outline',
        outlineApiKey: 'outline-key',
        radicaleBaseUrl: 'http://radicale',
        radicaleUsername: 'user',
        radicalePassword: 'pass',
        adminIds: ['@admin:server'],
        botName: 'TestBot',
        databasePath: '/tmp/test.db',
        logLevel: 'debug',
      );

      expect(env.anthropicApiKey, equals('custom-key'));
      expect(env.matrixHomeserver, equals('https://matrix.custom'));
      expect(env.matrixAccessToken, equals('custom-token'));
      expect(env.matrixUsername, equals('bot'));
      expect(env.matrixPassword, equals('secret'));
      expect(env.matrixIgnoreRooms, equals(['!ignore:server']));
      expect(env.kanBaseUrl, equals('http://kan'));
      expect(env.kanApiKey, equals('kan-key'));
      expect(env.outlineBaseUrl, equals('http://outline'));
      expect(env.outlineApiKey, equals('outline-key'));
      expect(env.radicaleBaseUrl, equals('http://radicale'));
      expect(env.radicaleUsername, equals('user'));
      expect(env.radicalePassword, equals('pass'));
      expect(env.adminIds, equals(['@admin:server']));
      expect(env.botName, equals('TestBot'));
      expect(env.databasePath, equals('/tmp/test.db'));
      expect(env.logLevel, equals('debug'));
    });
  });

  group('kanEnabled', () {
    test('returns false when kanApiKey is null', () {
      final env = Env.forTesting();
      expect(env.kanEnabled, isFalse);
    });

    test('returns false when kanApiKey is empty', () {
      final env = Env.forTesting(kanApiKey: '');
      expect(env.kanEnabled, isFalse);
    });

    test('returns true when kanApiKey is set', () {
      final env = Env.forTesting(kanApiKey: 'my-key');
      expect(env.kanEnabled, isTrue);
    });
  });

  group('outlineEnabled', () {
    test('returns false when outlineApiKey is null', () {
      final env = Env.forTesting();
      expect(env.outlineEnabled, isFalse);
    });

    test('returns false when outlineApiKey is empty', () {
      final env = Env.forTesting(outlineApiKey: '');
      expect(env.outlineEnabled, isFalse);
    });

    test('returns true when outlineApiKey is set', () {
      final env = Env.forTesting(outlineApiKey: 'my-key');
      expect(env.outlineEnabled, isTrue);
    });
  });

  group('radicaleEnabled', () {
    test('returns false when radicalePassword is null', () {
      final env = Env.forTesting();
      expect(env.radicaleEnabled, isFalse);
    });

    test('returns false when radicalePassword is empty', () {
      final env = Env.forTesting(radicalePassword: '');
      expect(env.radicaleEnabled, isFalse);
    });

    test('returns true when radicalePassword is set', () {
      final env = Env.forTesting(radicalePassword: 'secret');
      expect(env.radicaleEnabled, isTrue);
    });
  });

  group('isAdmin', () {
    test('returns false when adminUuids is empty', () {
      final env = Env.forTesting();
      expect(env.isAdmin('uuid-1'), isFalse);
    });

    test('returns false for null uuid', () {
      final env = Env.forTesting(adminIds: ['uuid-admin']);
      expect(env.isAdmin(null), isFalse);
    });

    test('returns false for non-admin uuid', () {
      final env = Env.forTesting(adminIds: ['uuid-admin']);
      expect(env.isAdmin('uuid-regular'), isFalse);
    });

    test('returns true for admin uuid', () {
      final env = Env.forTesting(adminIds: ['uuid-admin-1', 'uuid-admin-2']);
      expect(env.isAdmin('uuid-admin-1'), isTrue);
      expect(env.isAdmin('uuid-admin-2'), isTrue);
    });
  });

  group('auth mode selection', () {
    test('useDirectBearer is false when no long-lived token set', () {
      final env = Env.forTesting();
      expect(env.useDirectBearer, isFalse);
    });

    test('useDirectBearer is true when a long-lived OAuth token is set', () {
      final env = Env.forTesting(claudeCodeOAuthToken: 'sk-ant-oat01-xyz');
      expect(env.useDirectBearer, isTrue);
    });

    test('blank long-lived token does not enable direct Bearer', () {
      final env = Env.forTesting(claudeCodeOAuthToken: '');
      expect(env.useDirectBearer, isFalse);
    });

    test('direct Bearer and refresh-token modes are independent', () {
      final env = Env.forTesting(
        claudeCodeOAuthToken: 'sk-ant-oat01-xyz',
        claudeRefreshToken: 'sk-ant-ort01-abc',
      );
      // Both getters report true; the entrypoint resolves precedence
      // (direct Bearer wins) — these flags just describe what's configured.
      expect(env.useDirectBearer, isTrue);
      expect(env.useOAuth, isTrue);
    });
  });

  group('isSelf (self-echo guard)', () {
    const bot = '@dreamfinder-bot:imagineering.cc';

    test('native bot MXID is always self', () {
      final env = Env.forTesting();
      expect(env.isSelf(bot, bot), isTrue);
    });

    test('relayed/bridged puppet MXIDs are self when configured', () {
      final env = Env.forTesting(selfPuppetIds: const [
        '@_relay_signal_8b12f8cf:imagineering.cc',
        '@telegram_8927028624:imagineering.cc',
      ]);
      expect(
          env.isSelf('@_relay_signal_8b12f8cf:imagineering.cc', bot), isTrue);
      expect(env.isSelf('@telegram_8927028624:imagineering.cc', bot), isTrue);
    });

    test('a different puppet (a real person) is not self', () {
      final env = Env.forTesting(selfPuppetIds: const [
        '@_relay_signal_8b12f8cf:imagineering.cc',
      ]);
      // A human's relay puppet must NOT be dropped, even if they're on the
      // same platform as one of River's puppets.
      expect(
          env.isSelf('@_relay_signal_9c2dfb33:imagineering.cc', bot), isFalse);
      expect(env.isSelf('@nick:imagineering.cc', bot), isFalse);
    });

    test('null sender is not self', () {
      final env = Env.forTesting();
      expect(env.isSelf(null, bot), isFalse);
    });
  });
}
