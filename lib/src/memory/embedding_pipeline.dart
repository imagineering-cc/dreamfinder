/// Async embedding pipeline that queues message pairs for background embedding.
///
/// After each conversation turn, the agent loop fires-and-forgets a call to
/// [EmbeddingPipeline.queue]. The pipeline batches pending texts, calls the
/// [EmbeddingClient], and stores the resulting vectors in SQLite. If the
/// embedding call fails, the source text is still stored (embedding = null)
/// so it can be retried later.
library;

import 'dart:developer' as developer;

import '../db/queries/memory_queries.dart';
import 'embedding_client.dart';
import 'memory_record.dart';

/// Minimum character length for a message to be worth embedding.
///
/// Very short messages ("ok", "thanks", "hi") carry no semantic value and
/// would dilute retrieval quality.
const _minSourceLength = 10;

/// Queues and processes message embeddings asynchronously.
///
/// Usage:
/// ```dart
/// pipeline.queue(
///   chatId: 'group-123',
///   userText: 'What is the Dawn Gate?',
///   assistantText: 'The Dawn Gate is an emoji gateway...',
///   senderUuid: 'abc-123',
///   senderName: 'Nick',
/// );
/// ```
class EmbeddingPipeline {
  EmbeddingPipeline({
    required EmbeddingClient client,
    required MemoryQueryAccessor queries,
    String Function()? getBotName,
  })  : _client = client,
        _queries = queries,
        _getBotName = getBotName ?? _defaultBotName;

  static String _defaultBotName() => 'Dreamfinder';

  final EmbeddingClient _client;
  final MemoryQueryAccessor _queries;

  /// Returns the current bot name. Called on each [queue] invocation so
  /// runtime identity changes (via `set_bot_identity`) are reflected
  /// immediately in stored source text.
  final String Function() _getBotName;

  /// Queues a user+assistant turn for embedding.
  ///
  /// Combines the messages into a single semantic unit, inserts the source
  /// text immediately, then asynchronously generates and stores the embedding.
  /// Returns immediately — embedding happens in the background.
  ///
  /// Skips messages that are too short or system-initiated.
  void queue({
    required String chatId,
    required String userText,
    required String assistantText,
    String? senderUuid,
    String? senderName,
    MemoryVisibility visibility = MemoryVisibility.sameChat,
  }) {
    final sourceText = '${senderName ?? "User"}: $userText\n'
        '${_getBotName()}: $assistantText';

    // Skip trivially short conversations.
    if (userText.length < _minSourceLength &&
        assistantText.length < _minSourceLength) {
      return;
    }

    // Insert the source text immediately so it's durable even if embedding
    // fails. The embedding column will be null until _processEmbedding
    // completes.
    final recordId = _queries.insertMemoryEmbedding(
      chatId: chatId,
      sourceType: MemorySourceType.message,
      sourceText: sourceText,
      senderUuid: senderUuid,
      senderName: senderName,
      visibility: visibility,
    );

    // Fire-and-forget the embedding call.
    _processEmbedding(recordId, sourceText);
  }

  /// Generates an embedding and updates the record.
  ///
  /// If the embedding call fails, the record remains with embedding = null.
  /// A future backfill job can retry these.
  Future<void> _processEmbedding(int recordId, String sourceText) async {
    try {
      final embeddings = await _client.embed([sourceText]);
      if (embeddings.isNotEmpty) {
        _queries.updateMemoryEmbedding(recordId, embeddings.first);
      }
    } on Exception catch (e) {
      developer.log(
        'Failed to embed memory $recordId: $e',
        name: 'EmbeddingPipeline',
        level: 900,
      );
      // Source text is already stored — embedding can be retried later.
    }
  }
}

/// Accessor interface for memory query operations needed by the pipeline.
///
/// This avoids a direct dependency on the full [Queries] class. The [Queries]
/// class satisfies this via the [MemoryQueries] mixin.
abstract class MemoryQueryAccessor {
  /// Inserts a memory embedding record and returns its row ID.
  int insertMemoryEmbedding({
    int? messageId,
    required String chatId,
    required MemorySourceType sourceType,
    required String sourceText,
    String? senderUuid,
    String? senderName,
    MemoryVisibility visibility,
    List<double>? embedding,
  });

  /// Updates the embedding BLOB for an existing memory record.
  void updateMemoryEmbedding(int id, List<double> embedding);
}
