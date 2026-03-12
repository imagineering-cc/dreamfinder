/// Retries embedding for records where the initial Voyage API call failed.
///
/// Both [EmbeddingPipeline] and [MemoryConsolidator] can produce records with
/// `embedding = NULL` when the Voyage API is down or rate-limited. This class
/// sweeps those orphans and re-attempts embedding, one record at a time with
/// per-record error isolation.
///
/// Scheduled by [Scheduler] to run before consolidation in the daily 3 AM
/// window, so freshly-embedded records are available for summarization.
library;

import 'dart:developer' as developer;

import '../db/queries.dart';
import 'embedding_client.dart';

/// Retries embedding for memory records that have `embedding = NULL`.
class EmbeddingBackfill {
  EmbeddingBackfill({
    required Queries queries,
    required EmbeddingClient client,
    this.batchLimit = 50,
  })  : _queries = queries,
        _client = client;

  final Queries _queries;
  final EmbeddingClient _client;

  /// Maximum number of records to process per backfill run.
  final int batchLimit;

  bool _running = false;

  /// Retries embedding for null-embedding records.
  ///
  /// Returns the number of records successfully embedded. Skips if already
  /// running (concurrent guard, same pattern as [MemoryConsolidator]).
  Future<int> backfill() async {
    if (_running) return 0;
    _running = true;

    try {
      final records = _queries.getUnembeddedRecords(limit: batchLimit);
      if (records.isEmpty) return 0;

      var successCount = 0;

      for (final record in records) {
        try {
          final embeddings = await _client.embed([record.sourceText]);
          if (embeddings.isNotEmpty) {
            _queries.updateMemoryEmbedding(record.id, embeddings.first);
            successCount++;
          }
        } on Exception catch (e) {
          developer.log(
            'Backfill failed for record ${record.id}: $e',
            name: 'EmbeddingBackfill',
            level: 900,
          );
          // Continue to next record — one failure doesn't block others.
        }
      }

      if (successCount > 0) {
        developer.log(
          'Backfilled $successCount/${records.length} records',
          name: 'EmbeddingBackfill',
        );
      }

      return successCount;
    } finally {
      _running = false;
    }
  }
}
