/// A probe that verifies a tool returns the *true content* of a known golden
/// record — not merely that it is wired (the PR1 `deep_search` wiring probe) but
/// that the bytes it returns are the sealed golden bytes.
///
/// This closes the deepest round-2 finding (§probe-integrity): a content-hollow
/// tool returns a well-formed-but-wrong/empty payload and sails past a wiring
/// check. By retrieving the golden record's `(payload, seal)` through the real
/// path and verifying the seal with the immune system's key, forgery and hollow
/// are both caught, and a poisoned corpus cannot fake a pass.
library;

import '../probe.dart';
import '../sentinel.dart';

/// Fetches the `(payload, seal)` a tool returns for a sentinel id via the real
/// path, or null when the record cannot be surfaced at all. Injected so the
/// probe is testable without a live corpus.
typedef SealedFetcher = Future<({String payload, String seal})?> Function(
  String sentinelId,
);

/// Retrieves a sentinel via a real tool path and verifies its HMAC seal.
///
/// Impedance-matched outcomes:
///
/// * fetcher not wired → [ProbeStatus.degraded] (a legitimately-off capability,
///   surfaced but not paged — mirrors RagProbe when retrieval is disabled).
/// * fetched `(payload, seal)` verifies → [ProbeStatus.ok] (the integration
///   returned the true golden content through the real path).
/// * sentinel not retrievable → [ProbeStatus.failed] (**content-hollow**: a doc
///   we KNOW exists could not be surfaced — the tool is semantically dead).
/// * fetched but the seal does not validate → [ProbeStatus.failed] (**forgery /
///   corruption**: the returned payload is not the sealed golden; an attacker
///   without the key cannot make this pass).
class ContentIntegrityProbe extends Probe {
  ContentIntegrityProbe({
    required String id,
    required this.sentinelId,
    required this.store,
    required this.sealer,
    SealedFetcher? fetchSealed,
    String owner = 'immune',
    DateTime? expiry,
  })  : _id = id,
        _fetch = fetchSealed,
        _owner = owner,
        _expiry = expiry;

  final String _id;

  /// The golden record's id, retrieved via the real path.
  final String sentinelId;

  /// The immune-owned, user-unwritable source of the expected sealed golden.
  final SentinelStore store;

  /// Verifies the fetched seal with the immune system's secret key.
  final SentinelSealer sealer;

  final SealedFetcher? _fetch;
  final String _owner;
  final DateTime? _expiry;

  @override
  String get id => _id;

  @override
  String get owner => _owner;

  @override
  DateTime? get expiry => _expiry;

  /// Pinned to the golden record's version so a corpus change that retires the
  /// sentinel is visible as a version, not a silent false failure.
  @override
  String? get sentinelVersion => store.sentinels[sentinelId]?.sentinel.version;

  @override
  Future<ProbeResult> run() async {
    final fetch = _fetch;
    if (fetch == null) {
      return ProbeResult(
        id: id,
        status: ProbeStatus.degraded,
        detail: 'content-integrity check disabled (no fetcher wired)',
        coverage: const ['integration-hollow', 'measurement-integrity'],
      );
    }

    final golden = store.sentinels[sentinelId];
    if (golden == null) {
      // Misconfiguration, not a River fault — but it means the probe cannot
      // assert anything, so it must not masquerade as healthy.
      return ProbeResult(
        id: id,
        status: ProbeStatus.failed,
        detail: 'no golden sentinel "$sentinelId" in the store — probe '
            'misconfigured',
        coverage: const ['measurement-integrity'],
      );
    }

    final fetched = await fetch(sentinelId);
    if (fetched == null) {
      return ProbeResult(
        id: id,
        status: ProbeStatus.failed,
        detail: 'sentinel "$sentinelId" not retrievable via the real path — '
            'content-hollow (a doc we KNOW exists could not be surfaced)',
        coverage: const ['integration-hollow', 'measurement-integrity'],
      );
    }

    // Two assertions, because HMAC authenticates ORIGIN, not equality to THIS
    // fixture:
    //  (1) the returned tuple carries a valid immune seal over its own bytes
    //      (integrity — a stripped/forged/corrupted seal fails), and
    //  (2) the returned payload IS the expected golden (identity — a replayed
    //      *alternate* immune-signed tuple with the same id+version but a
    //      different payload must NOT pass). This is the "invariants assert
    //      identity, not non-emptiness" rule turned on the probe itself.
    final candidate = Sentinel(
      id: sentinelId,
      payload: fetched.payload,
      version: golden.sentinel.version,
    );
    final sealValid = sealer.verify(candidate, fetched.seal);
    final isGolden =
        constantTimeEquals(fetched.payload, golden.sentinel.payload);
    if (!sealValid || !isGolden) {
      return ProbeResult(
        id: id,
        status: ProbeStatus.failed,
        detail: 'sentinel "$sentinelId" failed integrity check — returned '
            'content is not the sealed golden (forged, corrupted, or a '
            'replayed alternate)',
        coverage: const ['integration-hollow', 'measurement-integrity'],
      );
    }

    return ProbeResult(
      id: id,
      status: ProbeStatus.ok,
      detail: 'content integrity verified for sentinel "$sentinelId" '
          '(v${golden.sentinel.version})',
      coverage: const ['integration-hollow', 'measurement-integrity'],
    );
  }
}
