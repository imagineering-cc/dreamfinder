import 'package:imagineering_pm_bot/src/config/env.dart';
import 'package:test/test.dart';

void main() {
  group('Env.forTesting', () {
    test('provides sensible defaults', () {
      final env = Env.forTesting();
      expect(env.anthropicApiKey, equals('test-key'));
      expect(env.signalApiUrl, equals('http://localhost:8080'));
      expect(env.signalPhoneNumber, equals('+1234567890'));
      expect(env.botName, equals('Dreamfinder'));
      expect(env.databasePath, equals('./data/bot.db'));
      expect(env.logLevel, equals('info'));
    });

    test('allows overriding all fields', () {
      final env = Env.forTesting(
        anthropicApiKey: 'custom-key',
        signalApiUrl: 'http://custom:9090',
        signalPhoneNumber: '+9876543210',
        kanBaseUrl: 'http://kan',
        kanApiKey: 'kan-key',
        outlineBaseUrl: 'http://outline',
        outlineApiKey: 'outline-key',
        radicaleBaseUrl: 'http://radicale',
        radicaleUsername: 'user',
        radicalePassword: 'pass',
        adminUuids: ['uuid-admin-1'],
        botName: 'TestBot',
        databasePath: '/tmp/test.db',
        logLevel: 'debug',
      );

      expect(env.anthropicApiKey, equals('custom-key'));
      expect(env.signalApiUrl, equals('http://custom:9090'));
      expect(env.signalPhoneNumber, equals('+9876543210'));
      expect(env.kanBaseUrl, equals('http://kan'));
      expect(env.kanApiKey, equals('kan-key'));
      expect(env.outlineBaseUrl, equals('http://outline'));
      expect(env.outlineApiKey, equals('outline-key'));
      expect(env.radicaleBaseUrl, equals('http://radicale'));
      expect(env.radicaleUsername, equals('user'));
      expect(env.radicalePassword, equals('pass'));
      expect(env.adminUuids, equals(['uuid-admin-1']));
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
      final env = Env.forTesting(adminUuids: ['uuid-admin']);
      expect(env.isAdmin(null), isFalse);
    });

    test('returns false for non-admin uuid', () {
      final env = Env.forTesting(adminUuids: ['uuid-admin']);
      expect(env.isAdmin('uuid-regular'), isFalse);
    });

    test('returns true for admin uuid', () {
      final env = Env.forTesting(adminUuids: ['uuid-admin-1', 'uuid-admin-2']);
      expect(env.isAdmin('uuid-admin-1'), isTrue);
      expect(env.isAdmin('uuid-admin-2'), isTrue);
    });
  });
}
