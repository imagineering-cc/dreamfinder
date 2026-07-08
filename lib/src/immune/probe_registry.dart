/// The [ProbeRegistry] runs a set of [Probe]s and collects their results.
library;

import 'dart:async';

import 'probe.dart';

/// Default hard timeout for a single probe run. A probe that exceeds this is
/// reported [ProbeStatus.unknown] — it can never block the tick, and an
/// uncertain read never pages. Keeps a slow probe from starving the scheduler
/// tick it rides on (an immune tick sharing the 60s scheduler must not delay
/// standup/nudges).
const _defaultProbeTimeout = Duration(seconds: 8);

/// Runs deterministic [Probe]s and collects [ProbeResult]s.
///
/// The registry owns the two safety properties that keep sensing cheap and
/// bounded:
///
/// 1. **Hard per-probe timeout** — every [Probe.run] is wrapped in a timeout;
///    a slow or hung probe degrades to [ProbeStatus.unknown] instead of
///    blocking every other probe (or the scheduler tick).
/// 2. **Throw isolation** — a probe that throws is reported
///    [ProbeStatus.unknown], never propagated. One broken probe can't take
///    down the run.
class ProbeRegistry {
  ProbeRegistry(
    this.probes, {
    Duration probeTimeout = _defaultProbeTimeout,
  }) : _probeTimeout = probeTimeout {
    // Admission control: PR1 is detect-only. A probe may READ (including a
    // read that costs, e.g. an embedding lookup), but must never mutate or send
    // to the outside world. Reject write/send probes at construction rather
    // than trusting the `sideEffect` label to be advisory.
    for (final probe in probes) {
      if (probe.sideEffect == SideEffect.idempotentWrite ||
          probe.sideEffect == SideEffect.externalSend) {
        throw ArgumentError(
          'Probe "${probe.id}" has side-effect ${probe.sideEffect.name}; the '
          'sensing spine admits only read/paidCall probes (no writes/sends).',
        );
      }
    }
  }

  /// The registered probes, run in order but independently.
  final List<Probe> probes;

  final Duration _probeTimeout;

  /// The ids of probes whose recalibration deadline ([Probe.expiry]) is at or
  /// before [now]. An expired antibody's baseline may be stale, so it should be
  /// flagged for refresh (its owner paged) rather than trusted silently — the
  /// sentinel-retirement discipline from the design. Probes with a null expiry
  /// never appear here.
  List<String> expired(DateTime now) => [
        for (final probe in probes)
          if (probe.expiry != null && !probe.expiry!.isAfter(now)) probe.id,
      ];

  /// Runs every probe with a hard timeout and throw-isolation. Never throws.
  Future<List<ProbeResult>> runAll() async {
    final results = <ProbeResult>[];
    for (final probe in probes) {
      results.add(await _runOne(probe));
    }
    return results;
  }

  Future<ProbeResult> _runOne(Probe probe) async {
    try {
      return await probe.run().timeout(_probeTimeout);
    } on TimeoutException {
      return ProbeResult(
        id: probe.id,
        status: ProbeStatus.unknown,
        detail: 'probe timed out after ${_probeTimeout.inSeconds}s',
      );
    } on Object catch (e) {
      // A thrown error means we could not assert anything — unknown, not
      // failed. An uncertain read must never drive an action.
      return ProbeResult(
        id: probe.id,
        status: ProbeStatus.unknown,
        detail: 'probe threw: $e',
      );
    }
  }
}
