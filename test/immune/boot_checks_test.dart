import 'package:dreamfinder/src/config/env.dart';
import 'package:dreamfinder/src/immune/boot_checks.dart';
import 'package:test/test.dart';

void main() {
  group('assertHardInvariants', () {
    test('throws when on metered-only auth with no maintenance override', () {
      final env = Env.forTesting(
        anthropicApiKey: 'metered-key',
        claudeCodeOAuthToken: null,
        claudeRefreshToken: null,
      );
      expect(
        () => assertHardInvariants(env),
        throwsA(isA<HardInvariantViolation>()),
      );
    });

    test('passes when on direct-Bearer OAuth', () {
      final env = Env.forTesting(claudeCodeOAuthToken: 'oauth-token');
      expect(() => assertHardInvariants(env), returnsNormally);
    });

    test('passes when on refresh-token OAuth', () {
      final env = Env.forTesting(
        anthropicApiKey: null,
        claudeRefreshToken: 'refresh-token',
      );
      expect(() => assertHardInvariants(env), returnsNormally);
    });

    test('passes on metered when maintenance override is explicitly set', () {
      final env = Env.forTesting(
        anthropicApiKey: 'metered-key',
        claudeCodeOAuthToken: null,
        claudeRefreshToken: null,
      );
      expect(
        () => assertHardInvariants(
          env,
          maintenanceMode: MaintenanceMode.meteredAllowed,
        ),
        returnsNormally,
      );
    });
  });

  group('MaintenanceMode.fromEnv', () {
    test('parses metered_allowed', () {
      expect(
        MaintenanceMode.fromEnv('metered_allowed'),
        MaintenanceMode.meteredAllowed,
      );
    });
    test('is case/format-insensitive (escape hatch must not fail on casing)',
        () {
      expect(MaintenanceMode.fromEnv('METERED_ALLOWED'),
          MaintenanceMode.meteredAllowed);
      expect(MaintenanceMode.fromEnv('metered-allowed'),
          MaintenanceMode.meteredAllowed);
      expect(MaintenanceMode.fromEnv('  Metered_Allowed  '),
          MaintenanceMode.meteredAllowed);
    });

    test('defaults to none for unknown/empty', () {
      expect(MaintenanceMode.fromEnv(null), MaintenanceMode.none);
      expect(MaintenanceMode.fromEnv(''), MaintenanceMode.none);
      expect(MaintenanceMode.fromEnv('nonsense'), MaintenanceMode.none);
    });
  });
}
