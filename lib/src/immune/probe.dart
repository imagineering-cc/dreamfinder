/// River's Immune System — the deterministic sensing layer.
///
/// A [Probe] invokes a real read-only path with a fixed input and asserts an
/// identity-based invariant on the result. Detection is *deterministic*: the
/// invariant is a plain Dart predicate over a materialized value — there is no
/// LLM anywhere in the sensing path, so River's own hallucination (or a
/// poisoned corpus) can never mark a broken tool healthy.
///
/// See `design/river-immune-system.html` for the full design. This is PR1: the
/// sensing spine (detect + escalate). No autonomous remediation lives here.
library;

/// The outcome of a single probe run.
///
/// The four states encode the immune system's core rule — *an action's power
/// must match the certainty of the observation driving it*:
///
/// * [ok] — the invariant held; nothing to do.
/// * [degraded] — a capability is legitimately unavailable (e.g. embeddings
///   disabled because `VOYAGE_API_KEY` is unset). Surfaced, but **does not
///   page** — it is not a fault, just a known-off capability.
/// * [failed] — the invariant was violated: River is up but *wrong*. This is
///   the silent-semantic class the whole system exists to catch. **Pages.**
/// * [unknown] — the probe could not complete (timeout / transport error), so
///   we cannot assert anything. Surfaced, but **does not page** — an
///   uncertain read may never drive an action.
enum ProbeStatus { ok, degraded, failed, unknown }

/// How much of the world a probe touches. PR1 probes are all [pureRead];
/// anything past that requires a sandbox target + sign-off (a PR2/PR3 concern).
enum SideEffect { pureRead, idempotentWrite, externalSend, paidCall }

/// The result of running one [Probe].
class ProbeResult {
  const ProbeResult({
    required this.id,
    required this.status,
    this.detail,
    this.coverage = const <String>[],
  });

  /// Stable probe id (also the escalation `kind`, e.g. `probe_deep_search`).
  final String id;

  /// The assessed status.
  final ProbeStatus status;

  /// Human-readable context for `/immune` and escalations (never fed to an LLM).
  final String? detail;

  /// The failure shapes this probe covers (e.g. `hollow`). Named honestly so
  /// `/immune` reflects *immune memory*, not general immunity.
  final List<String> coverage;

  /// Only [ProbeStatus.failed] escalates. [degraded] and [unknown] are surfaced
  /// on `/immune` but never page — the impedance-match rule, in code.
  bool get shouldPage => status == ProbeStatus.failed;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'status': status.name,
        if (detail != null) 'detail': detail,
        if (coverage.isNotEmpty) 'coverage': coverage,
      };
}

/// A deterministic, read-only health probe.
///
/// Implementations invoke a real collaborator (injected via their constructor,
/// never a global) and return a [ProbeResult]. They must be cheap and bounded;
/// the [ProbeRegistry] enforces a hard timeout around every [run].
abstract class Probe {
  /// Stable identifier; used as the `/immune` key and escalation `kind`.
  String get id;

  /// PR1 probes are all read-only.
  SideEffect get sideEffect => SideEffect.pureRead;

  /// The team/owner responsible for this antibody's lifecycle — who is paged
  /// when it flakes and who refreshes an expired sentinel. Defaults to `immune`.
  /// (Immune-memory discipline: monotonic growth without an owner is how a
  /// registry drifts into autoimmunity.)
  String get owner => 'immune';

  /// Version of the golden data/sentinel this probe depends on, or null for a
  /// probe with no external golden. A corpus/schema change bumps this to
  /// *retire* the sentinel rather than silently *fire* a false failure.
  String? get sentinelVersion => null;

  /// Recalibration deadline. Past this instant the registry flags the probe as
  /// expired (its baseline may be stale) instead of trusting it silently. Null
  /// = never expires.
  DateTime? get expiry => null;

  /// Invoke the real path and assert the invariant. Must not throw for an
  /// *expected* failure — return [ProbeStatus.failed]/[degraded] instead. The
  /// registry treats a thrown error as [ProbeStatus.unknown].
  Future<ProbeResult> run();
}
