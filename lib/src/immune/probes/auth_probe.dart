/// Antibody for the metered-drift incident (River ran ~8 days silently on the
/// metered API after a redeploy dropped the OAuth token, while `/health`
/// reported ok).
library;

import '../boot_checks.dart';
import '../probe.dart';

/// Asserts River is running on OAuth, not the metered API.
///
/// Reads the live auth-mode label (the same mutable label the alerter surfaces,
/// e.g. `OAuth (Claude Max)` / `API key`). This is River's *own* config read
/// in-process — the deployed truth, not the repo or memory.
class AuthProbe extends Probe {
  AuthProbe({
    required String Function() readAuthModeLabel,
    this.maintenanceMode = MaintenanceMode.none,
  }) : _readAuthModeLabel = readAuthModeLabel;

  final String Function() _readAuthModeLabel;

  /// When an operator has declared a metered maintenance window, a non-OAuth
  /// label is `degraded` (expected), not `failed` (drift).
  final MaintenanceMode maintenanceMode;

  @override
  String get id => 'probe_auth';

  @override
  Future<ProbeResult> run() async {
    final label = _readAuthModeLabel();
    // Detect metered by the presence of "api key", NOT the absence of "oauth":
    // the fallback label is literally "API key (OAuth fallback)", which
    // contains "oauth" — a substring check for oauth would false-negative the
    // exact drift this probe exists to catch (River fell back to metered).
    final onMetered = label.toLowerCase().contains('api key');
    final onOAuth = !onMetered;

    if (onOAuth) {
      return ProbeResult(
        id: id,
        status: ProbeStatus.ok,
        detail: 'auth mode: $label',
        coverage: const ['config-drift', 'metered-drift'],
      );
    }
    if (maintenanceMode == MaintenanceMode.meteredAllowed) {
      return ProbeResult(
        id: id,
        status: ProbeStatus.degraded,
        detail: 'auth mode: $label (metered maintenance window — allowed)',
        coverage: const ['config-drift', 'metered-drift'],
      );
    }
    return ProbeResult(
      id: id,
      status: ProbeStatus.failed,
      detail: 'auth mode is "$label", not OAuth — metered drift (never-metered '
          'rule). Restore CLAUDE_CODE_OAUTH_TOKEN.',
      coverage: const ['config-drift', 'metered-drift'],
    );
  }
}
