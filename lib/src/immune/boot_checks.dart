/// Boot-time hard invariants for River's Immune System (Layer 0).
///
/// The design splits boot checks into two tiers:
///
/// * **Hard invariants** (this file) — local, deterministic, *certain* when
///   they fail. Violating one means River cannot serve *correctly*, so it
///   withholds readiness (`/ready` stays red). These never depend on a remote
///   service, so they can't false-positive on a network blip.
/// * **Degraded-readiness** (the probe run at boot) — remote/semantic checks
///   that *degrade* a capability and escalate, but never block startup. Lives
///   in the probe layer, not here.
///
/// The cardinal rule: *fail loud, not fail-to-boot.* Only a check that is
/// certainly a misconfiguration when it fails may gate startup.
library;

import '../config/env.dart';

/// Explicit operator override for otherwise-blocking boot states.
///
/// Without this, "River is on the metered API, not OAuth" is a hard-invariant
/// violation (it's the 8-day silent-metered-drift class, blocked at t=0). But a
/// legitimate maintenance boot needs an escape hatch — otherwise the negative
/// fixture "intentional OAuth-off maintenance" contradicts the invariant. That
/// escape hatch is [MaintenanceMode.meteredAllowed], set explicitly by an
/// operator, never inferred.
enum MaintenanceMode {
  /// Normal operation — auth must resolve to OAuth.
  none,

  /// Operator has explicitly allowed running on the metered API for a
  /// maintenance window. Boot proceeds; the auth probe reports `degraded`
  /// (not `failed`) so it does not page.
  meteredAllowed;

  /// Parses `MAINTENANCE_MODE` env values (case/format-insensitive — this is an
  /// emergency escape hatch, so silent rejection on casing would be brittle).
  /// Unknown/empty → [none].
  static MaintenanceMode fromEnv(String? raw) =>
      switch (raw?.trim().toLowerCase().replaceAll('-', '_')) {
        'metered_allowed' => MaintenanceMode.meteredAllowed,
        _ => MaintenanceMode.none,
      };
}

/// Thrown when a hard invariant is violated. Boot should catch this, withhold
/// readiness, and escalate — it must NOT be swallowed into a healthy-looking
/// state.
class HardInvariantViolation implements Exception {
  const HardInvariantViolation(this.message);
  final String message;
  @override
  String toString() => 'HardInvariantViolation: $message';
}

/// Asserts the boot hard invariants. Throws [HardInvariantViolation] on the
/// first violation.
///
/// Currently enforces the never-metered rule: River must be on a real OAuth
/// path (direct-Bearer or refresh-token) unless an operator has explicitly set
/// [MaintenanceMode.meteredAllowed]. This is the boot-time antibody for the
/// metered-drift incident — a redeploy that silently drops the OAuth token now
/// fails readiness instead of running metered for days.
void assertHardInvariants(
  Env env, {
  MaintenanceMode maintenanceMode = MaintenanceMode.none,
}) {
  final onOAuth = env.useDirectBearer || env.useOAuth;
  if (!onOAuth && maintenanceMode != MaintenanceMode.meteredAllowed) {
    throw const HardInvariantViolation(
      'auth did not resolve to OAuth (direct-Bearer or refresh-token) and no '
      'MAINTENANCE_MODE=metered_allowed override is set — refusing readiness '
      'to avoid silently running on the metered API. Set CLAUDE_CODE_OAUTH_TOKEN, '
      'or set MAINTENANCE_MODE=metered_allowed to override for a maintenance window.',
    );
  }
}
