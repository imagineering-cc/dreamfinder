/// Antibody for dead RAG retrieval (long-term memory silently returning nothing
/// — e.g. `VOYAGE_API_KEY` unset, so River answers "I don't have that" when it
/// should recall).
library;

import '../probe.dart';

/// Returns the number of results for a fixed probe query, or throws. Injected so
/// the probe is testable and decoupled from the retriever/embedding stack.
typedef RagRetrieveCount = Future<int> Function();

/// Asserts long-term memory retrieval is alive.
///
/// * retrieval disabled (embeddings off, e.g. `VOYAGE_API_KEY` unset) →
///   `degraded`: a legitimately-off capability, surfaced but not paged.
/// * retrieval returns > 0 → `ok`.
/// * retrieval returns 0 → `degraded`, not `failed`: an empty corpus and a
///   broken embedder are indistinguishable from a count alone (ambiguous read →
///   degrade, don't page). Content-level assurance is a PR2 fixture gate.
class RagProbe extends Probe {
  RagProbe({RagRetrieveCount? retrieveCount}) : _retrieveCount = retrieveCount;

  /// Null when retrieval is disabled (no embedding client wired).
  final RagRetrieveCount? _retrieveCount;

  @override
  String get id => 'probe_rag';

  // Retrieval embeds the query via the embedding provider (Voyage) — a paid
  // remote call, NOT a pure local read. Labelled honestly so the registry's
  // admission control and future budget accounting can see it.
  @override
  SideEffect get sideEffect => SideEffect.paidCall;

  @override
  Future<ProbeResult> run() async {
    final fn = _retrieveCount;
    if (fn == null) {
      return ProbeResult(
        id: id,
        status: ProbeStatus.degraded,
        detail: 'RAG retrieval disabled (no embedding client — VOYAGE_API_KEY '
            'unset)',
        coverage: const ['integration-hollow'],
      );
    }
    final count = await fn();
    if (count > 0) {
      return ProbeResult(
        id: id,
        status: ProbeStatus.ok,
        detail: 'RAG retrieval returned $count result(s)',
        coverage: const ['integration-hollow'],
      );
    }
    return ProbeResult(
      id: id,
      status: ProbeStatus.degraded,
      detail: 'RAG retrieval returned zero — empty corpus or failing embedder '
          '(ambiguous; surfaced, not paged)',
      coverage: const ['integration-hollow'],
    );
  }
}
