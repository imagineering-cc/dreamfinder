/// Periodic consolidator that summarizes old conversation embeddings.
///
/// Over time, fine-grained message embeddings accumulate and dilute retrieval
/// quality. The consolidator batches old embeddings per chat, summarizes them
/// via [SummarizationClient], and replaces the originals with compact summary
/// embeddings — similar to LSM-tree compaction.
///
/// Scheduling is handled by [Scheduler], which calls [consolidate] during its
/// daily cleanup window. A watermark per chat ensures idempotent re-runs.
library;

import 'dart:developer' as developer;

import '../db/queries.dart';
import 'embedding_client.dart';
import 'memory_record.dart';
import 'summarization_client.dart';

/// Consolidates old message embeddings into summary embeddings.
///
/// See the module doc comment for the full algorithm.
class MemoryConsolidator {
  MemoryConsolidator({
    required Queries queries,
    required SummarizationClient summarizer,
    required EmbeddingClient embeddingClient,
    this.batchSize = 20,
    this.minAgeHours = 48,
  })  : _queries = queries,
        _summarizer = summarizer,
        _embeddingClient = embeddingClient;

  final Queries _queries;
  final SummarizationClient _summarizer;
  final EmbeddingClient _embeddingClient;

  /// Number of messages per summary batch.
  final int batchSize;

  /// Only consolidate memories older than this many hours.
  final int minAgeHours;

  bool _running = false;

  /// Runs one consolidation pass across all chats.
  ///
  /// Skips if already running (concurrent guard). Catches exceptions per-chat
  /// so one failing chat doesn't block others.
  Future<void> consolidate() async {
    if (_running) return;
    _running = true;

    try {
      final chatIds = _queries.getChatsWithUnconsolidatedMemories();

      for (final chatId in chatIds) {
        try {
          await _consolidateChat(chatId);
        } on Exception catch (e) {
          developer.log(
            'Consolidation failed for chat $chatId: $e',
            name: 'MemoryConsolidator',
            level: 900,
          );
        }
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _consolidateChat(String chatId) async {
    final watermark = _queries.getLastConsolidatedId(chatId);
    final candidates = _queries.getUnconsolidatedMemories(
      chatId,
      afterId: watermark,
      minAgeHours: minAgeHours,
    );

    if (candidates.isEmpty) return;

    // Group by visibility.
    final grouped = <MemoryVisibility, List<MemoryRecord>>{};
    for (final memory in candidates) {
      grouped.putIfAbsent(memory.visibility, () => []).add(memory);
    }

    var maxIdProcessed = watermark;

    for (final entry in grouped.entries) {
      final visibility = entry.key;
      final memories = entry.value;

      if (memories.length < batchSize) continue;

      final batch = memories.take(batchSize).toList();
      final idFrom = batch.first.id;
      final idTo = batch.last.id;

      // Summarize the batch.
      String summaryText;
      try {
        summaryText = await _summarizer.summarize(
          batch.map((m) => m.sourceText).toList(),
        );
      } on Exception catch (e) {
        developer.log(
          'Summarization failed for $chatId (${visibility.dbValue}): $e',
          name: 'MemoryConsolidator',
          level: 900,
        );
        // Don't delete originals or advance watermark on failure.
        continue;
      }

      // Atomic: insert summary + delete originals.
      _queries.runInTransaction(() {
        _queries.insertMemorySummary(
          chatId: chatId,
          summaryText: summaryText,
          messageIdFrom: idFrom,
          messageIdTo: idTo,
          messageCount: batch.length,
        );

        _queries.insertMemoryEmbedding(
          chatId: chatId,
          sourceType: MemorySourceType.summary,
          sourceText: summaryText,
          visibility: visibility,
        );

        _queries.deleteMemoryEmbeddings(batch.map((m) => m.id).toList());
      });

      // Fire-and-forget: embed the summary text.
      await _embedSummary(chatId, summaryText);

      if (idTo > maxIdProcessed) {
        maxIdProcessed = idTo;
      }

      developer.log(
        'Consolidated ${batch.length} ${visibility.dbValue} memories '
        'for $chatId (ids $idFrom–$idTo)',
        name: 'MemoryConsolidator',
      );
    }

    if (maxIdProcessed > watermark) {
      _queries.setLastConsolidatedId(chatId, maxIdProcessed);
    }
  }

  /// Embeds a summary text and updates the most recent summary embedding
  /// record that lacks an embedding.
  Future<void> _embedSummary(String chatId, String summaryText) async {
    try {
      final embeddings = await _embeddingClient.embed([summaryText]);
      if (embeddings.isEmpty) return;

      // Find the summary record without an embedding.
      final rows = _queries.db.handle.select(
        'SELECT id FROM memory_embeddings '
        "WHERE chat_id = ? AND source_type = 'summary' AND embedding IS NULL "
        'AND source_text = ? ORDER BY id DESC LIMIT 1',
        [chatId, summaryText],
      );
      if (rows.isNotEmpty) {
        _queries.updateMemoryEmbedding(
          rows.first['id'] as int,
          embeddings.first,
        );
      }
    } on Exception catch (e) {
      developer.log(
        'Failed to embed summary for $chatId: $e',
        name: 'MemoryConsolidator',
        level: 900,
      );
      // Summary text is stored — embedding can be retried later.
    }
  }
}
