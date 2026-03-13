/// Query mixin for the memory embedding tables.
///
/// Provides insert, search, and consolidation-tracking operations for the
/// RAG memory system. Embeddings are stored as raw float32 bytes in a BLOB
/// column — cosine similarity is computed in Dart, not SQL.
library;

import 'dart:typed_data';

import '../../memory/memory_record.dart';
import '../database.dart';

/// Mixin providing CRUD operations for the `memory_embeddings`,
/// `memory_summaries`, and `memory_consolidation_state` tables.
mixin MemoryQueries {
  /// The database handle. Provided by the mixing-in class.
  BotDatabase get db;

  /// Inserts a memory embedding record and returns its row ID.
  int insertMemoryEmbedding({
    int? messageId,
    required String chatId,
    required MemorySourceType sourceType,
    required String sourceText,
    String? senderUuid,
    String? senderName,
    MemoryVisibility visibility = MemoryVisibility.sameChat,
    List<double>? embedding,
  }) {
    final blob = embedding != null ? _doublesToBlob(embedding) : null;
    db.handle.execute(
      '''INSERT INTO memory_embeddings
         (message_id, chat_id, source_type, source_text, sender_uuid,
          sender_name, visibility, embedding)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        messageId,
        chatId,
        sourceType.dbValue,
        sourceText,
        senderUuid,
        senderName,
        visibility.dbValue,
        blob,
      ],
    );
    return db.handle.lastInsertRowId;
  }

  /// Updates the embedding BLOB for an existing memory record.
  void updateMemoryEmbedding(int id, List<double> embedding) {
    db.handle.execute(
      'UPDATE memory_embeddings SET embedding = ? WHERE id = ?',
      [_doublesToBlob(embedding), id],
    );
  }

  /// Returns all memory records that have embeddings, optionally filtered by
  /// [chatId] and/or [visibility] levels.
  ///
  /// Used by [MemoryRetriever] for brute-force cosine similarity search.
  /// The caller handles ranking — this just fetches candidates.
  List<MemoryRecord> getEmbeddedMemories({
    String? chatId,
    List<MemoryVisibility>? visibilities,
  }) {
    final where = <String>[];
    final params = <Object?>[];

    where.add('embedding IS NOT NULL');

    if (chatId != null) {
      where.add('chat_id = ?');
      params.add(chatId);
    }

    if (visibilities != null && visibilities.isNotEmpty) {
      final placeholders = List.filled(visibilities.length, '?').join(', ');
      where.add('visibility IN ($placeholders)');
      params.addAll(visibilities.map((v) => v.dbValue));
    }

    final sql = 'SELECT * FROM memory_embeddings'
        '${where.isNotEmpty ? " WHERE ${where.join(" AND ")}" : ""}'
        ' ORDER BY created_at DESC';

    final rows = db.handle.select(sql, params);
    return [for (final row in rows) _memoryFromRow(row)];
  }

  /// Returns all memory records visible from [queryChatId].
  ///
  /// This implements the privacy model:
  /// - `same_chat` records from [queryChatId]
  /// - `cross_chat` records from any chat
  /// - `private` records only if [queryChatId] matches the record's chat
  ///
  /// In practice, same_chat and private both filter by chat_id — the
  /// distinction matters for 1:1 vs group chats at the assignment level.
  List<MemoryRecord> getVisibleMemories(
    String queryChatId, {
    int limit = 1000,
  }) {
    final rows = db.handle.select(
      '''SELECT * FROM memory_embeddings
         WHERE embedding IS NOT NULL
         AND (
           visibility = 'cross_chat'
           OR chat_id = ?
         )
         ORDER BY created_at DESC
         LIMIT ?''',
      [queryChatId, limit],
    );
    return [for (final row in rows) _memoryFromRow(row)];
  }

  /// Returns memory records that have no embedding vector yet.
  ///
  /// These are records where the Voyage API call failed during initial
  /// embedding (in [EmbeddingPipeline] or [MemoryConsolidator]). Ordered by
  /// `id ASC` so the oldest orphans are retried first.
  List<MemoryRecord> getUnembeddedRecords({int limit = 50}) {
    final rows = db.handle.select(
      'SELECT * FROM memory_embeddings WHERE embedding IS NULL '
      'ORDER BY id ASC LIMIT ?',
      [limit],
    );
    return [for (final row in rows) _memoryFromRow(row)];
  }

  /// Returns the total number of memory embedding records.
  int countMemoryEmbeddings() {
    final rows = db.handle.select(
      'SELECT count(*) as cnt FROM memory_embeddings',
    );
    return rows.first['cnt'] as int;
  }

  /// Returns the IDs of messages that already have embeddings in a chat.
  ///
  /// Used to skip re-embedding messages that were already processed.
  Set<int> getEmbeddedMessageIds(String chatId) {
    final rows = db.handle.select(
      'SELECT message_id FROM memory_embeddings '
      'WHERE chat_id = ? AND message_id IS NOT NULL',
      [chatId],
    );
    return {for (final row in rows) row['message_id'] as int};
  }

  // ---------------------------------------------------------------------------
  // Consolidation queries
  // ---------------------------------------------------------------------------

  /// Returns distinct chat IDs that have unconsolidated message-type embeddings.
  List<String> getChatsWithUnconsolidatedMemories() {
    final rows = db.handle.select(
      'SELECT DISTINCT chat_id FROM memory_embeddings '
      "WHERE source_type = 'message'",
    );
    return [for (final row in rows) row['chat_id'] as String];
  }

  /// Returns message-type embeddings for [chatId] that are eligible for
  /// consolidation: ID greater than [afterId] and created more than
  /// [minAgeHours] ago. Ordered by `id ASC`.
  List<MemoryRecord> getUnconsolidatedMemories(
    String chatId, {
    required int afterId,
    required int minAgeHours,
  }) {
    final rows = db.handle.select(
      'SELECT * FROM memory_embeddings '
      "WHERE chat_id = ? AND source_type = 'message' "
      'AND id > ? '
      "AND created_at < datetime('now', '-$minAgeHours hours') "
      'ORDER BY id ASC',
      [chatId, afterId],
    );
    return [for (final row in rows) _memoryFromRow(row)];
  }

  /// Inserts a summary provenance record and returns its row ID.
  int insertMemorySummary({
    required String chatId,
    required String summaryText,
    required int messageIdFrom,
    required int messageIdTo,
    required int messageCount,
  }) {
    db.handle.execute(
      '''INSERT INTO memory_summaries
         (chat_id, summary_text, message_id_from, message_id_to, message_count)
         VALUES (?, ?, ?, ?, ?)''',
      [chatId, summaryText, messageIdFrom, messageIdTo, messageCount],
    );
    return db.handle.lastInsertRowId;
  }

  /// Deletes memory embeddings by their IDs.
  ///
  /// Used by the consolidator to remove originals after summarization.
  void deleteMemoryEmbeddings(List<int> ids) {
    if (ids.isEmpty) return;
    final placeholders = List.filled(ids.length, '?').join(', ');
    db.handle.execute(
      'DELETE FROM memory_embeddings WHERE id IN ($placeholders)',
      ids,
    );
  }

  /// Executes [action] inside a SQLite transaction.
  ///
  /// Commits on success, rolls back on any exception (then rethrows).
  void runInTransaction(void Function() action) {
    db.handle.execute('BEGIN');
    try {
      action();
      db.handle.execute('COMMIT');
    } on Object {
      db.handle.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Finds the most recent summary embedding record for [chatId] that has
  /// no embedding vector yet, matching [sourceText]. Returns its ID, or null.
  ///
  /// Used by [MemoryConsolidator] to backfill embeddings after summarization.
  int? findUnembeddedSummary(String chatId, String sourceText) {
    final rows = db.handle.select(
      'SELECT id FROM memory_embeddings '
      "WHERE chat_id = ? AND source_type = 'summary' AND embedding IS NULL "
      'AND source_text = ? ORDER BY id DESC LIMIT 1',
      [chatId, sourceText],
    );
    if (rows.isEmpty) return null;
    return rows.first['id'] as int;
  }

  // ---------------------------------------------------------------------------
  // Consolidation state
  // ---------------------------------------------------------------------------

  /// Returns the last consolidated message ID for a chat, or 0 if none.
  int getLastConsolidatedId(String chatId) {
    final rows = db.handle.select(
      'SELECT last_consolidated_id FROM memory_consolidation_state '
      'WHERE chat_id = ?',
      [chatId],
    );
    if (rows.isEmpty) return 0;
    return rows.first['last_consolidated_id'] as int;
  }

  /// Updates the consolidation watermark for a chat.
  void setLastConsolidatedId(String chatId, int messageId) {
    db.handle.execute(
      '''INSERT INTO memory_consolidation_state
         (chat_id, last_consolidated_id, last_consolidated_at)
         VALUES (?, ?, datetime('now'))
         ON CONFLICT(chat_id) DO UPDATE SET
           last_consolidated_id = excluded.last_consolidated_id,
           last_consolidated_at = excluded.last_consolidated_at''',
      [chatId, messageId],
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Converts a list of doubles to a raw float32 byte buffer for BLOB storage.
  Uint8List _doublesToBlob(List<double> values) {
    final float32 = Float32List.fromList(values);
    return float32.buffer.asUint8List();
  }

  /// Converts a raw float32 BLOB back to a list of doubles.
  List<double> _blobToDoubles(Uint8List blob) {
    final float32 = blob.buffer.asFloat32List();
    return float32.toList();
  }

  MemoryRecord _memoryFromRow(Map<String, Object?> row) {
    final embeddingBlob = row['embedding'];
    List<double>? embedding;
    if (embeddingBlob is Uint8List) {
      embedding = _blobToDoubles(embeddingBlob);
    }

    return MemoryRecord(
      id: row['id'] as int,
      messageId: row['message_id'] as int?,
      chatId: row['chat_id'] as String,
      sourceType: MemorySourceType.fromDb(row['source_type'] as String),
      sourceText: row['source_text'] as String,
      senderUuid: row['sender_uuid'] as String?,
      senderName: row['sender_name'] as String?,
      visibility: MemoryVisibility.fromDb(row['visibility'] as String),
      embedding: embedding,
      createdAt: row['created_at'] as String,
    );
  }
}
