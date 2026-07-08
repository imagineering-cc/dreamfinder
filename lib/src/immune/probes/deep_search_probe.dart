/// Antibody for the integration-hollow incident (`deep_search` returned empty
/// for 11 commits after the MCP→CLI migration gated it on retired tool names —
/// it reported "sources: none" while looking healthy).
library;

import 'dart:convert';

import '../probe.dart';

/// Signature of `ToolRegistry.executeTool`, injected so the probe is testable
/// without a live agent/MCP stack.
typedef ToolExecutor = Future<String> Function(
  String toolName,
  Map<String, dynamic> args,
);

/// Runs `deep_search` with a fixed query and asserts the integration is
/// actually *wired* — i.e. it searched at least one source and none errored.
///
/// The key signal is **`sources_searched` being empty**, not `total_count == 0`.
/// The historical hollow returned "sources: none" — the tool searched nothing
/// because it was gated on retired names. Zero *results* can be legitimate (no
/// match for the query); zero *sources searched* cannot. (Content-level hollow
/// detection via a fixture-isolated sentinel is a PR2 measurement-integrity
/// gate.)
class DeepSearchProbe extends Probe {
  DeepSearchProbe({
    required ToolExecutor executeTool,
    this.query = 'Imagineering',
    this.sources = const ['memory'],
  }) : _executeTool = executeTool;

  final ToolExecutor _executeTool;

  /// A fixed, benign query. Its *content* is not asserted (PR1) — only that the
  /// integration searched and did not error.
  final String query;

  /// Which sources to ask for.
  final List<String> sources;

  @override
  String get id => 'probe_deep_search';

  @override
  Future<ProbeResult> run() async {
    final raw = await _executeTool('deep_search', <String, dynamic>{
      'query': query,
      'sources': sources,
      'limit': 3,
    });
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      return ProbeResult(
        id: id,
        status: ProbeStatus.failed,
        detail: 'deep_search returned a non-object payload',
        coverage: const ['integration-hollow'],
      );
    }

    // An explicit tool error → failed.
    final error = decoded['error'];
    if (error != null) {
      return ProbeResult(
        id: id,
        status: ProbeStatus.failed,
        detail: 'deep_search error: $error',
        coverage: const ['integration-hollow'],
      );
    }

    final searched = (decoded['sources_searched'] as List?) ?? const [];
    final failed = (decoded['sources_failed'] as List?) ?? const [];

    if (failed.isNotEmpty) {
      return ProbeResult(
        id: id,
        status: ProbeStatus.failed,
        detail: 'deep_search source(s) errored: $failed',
        coverage: const ['integration-hollow'],
      );
    }
    if (searched.isEmpty) {
      // The exact 11-commit signal: the tool searched nothing.
      return ProbeResult(
        id: id,
        status: ProbeStatus.failed,
        detail: 'deep_search searched zero sources — integration is wired off '
            '(the hollow-tool signal)',
        coverage: const ['integration-hollow'],
      );
    }
    return ProbeResult(
      id: id,
      status: ProbeStatus.ok,
      detail: 'deep_search searched $searched, total_count='
          '${decoded['total_count']}',
      coverage: const ['integration-hollow'],
    );
  }
}
