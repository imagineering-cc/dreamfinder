/// Data classes for the RAG memory system.
///
/// [MemoryRecord] represents a stored embedding with its source text and
/// metadata. [MemorySearchResult] pairs a record with its similarity score
/// for ranked retrieval results.
library;

/// Visibility level controlling where a memory can be retrieved.
///
/// Privacy boundaries prevent cross-chat leakage while allowing explicitly
/// shared knowledge (like identity changes) to flow everywhere.
enum MemoryVisibility {
  /// Retrievable only within the same group chat.
  sameChat('same_chat'),

  /// Retrievable from any chat (e.g., identity changes, admin 1:1 chats).
  crossChat('cross_chat'),

  /// Retrievable only within the same 1:1 conversation.
  private_('private');

  const MemoryVisibility(this.dbValue);

  /// The value stored in the database column.
  final String dbValue;

  /// Parses a database column value into a [MemoryVisibility].
  static MemoryVisibility fromDb(String value) => switch (value) {
        'same_chat' => sameChat,
        'cross_chat' => crossChat,
        'private' => private_,
        _ => throw ArgumentError('Unknown visibility: $value'),
      };
}

/// The type of content that was embedded.
enum MemorySourceType {
  /// A user message + assistant response pair.
  message('message'),

  /// A consolidated summary of older conversations.
  summary('summary');

  const MemorySourceType(this.dbValue);

  /// The value stored in the database column.
  final String dbValue;

  /// Parses a database column value into a [MemorySourceType].
  static MemorySourceType fromDb(String value) => switch (value) {
        'message' => message,
        'summary' => summary,
        _ => throw ArgumentError('Unknown source type: $value'),
      };
}

/// A stored memory embedding with its source text and metadata.
class MemoryRecord {
  const MemoryRecord({
    required this.id,
    this.messageId,
    required this.chatId,
    required this.sourceType,
    required this.sourceText,
    this.senderUuid,
    this.senderName,
    required this.visibility,
    this.embedding,
    required this.createdAt,
  });

  final int id;

  /// Link back to the messages table for provenance. Null for summaries.
  final int? messageId;
  final String chatId;
  final MemorySourceType sourceType;
  final String sourceText;
  final String? senderUuid;
  final String? senderName;
  final MemoryVisibility visibility;

  /// Raw float32 embedding as a list of doubles. Null if not yet embedded.
  final List<double>? embedding;
  final String createdAt;
}

/// A [MemoryRecord] paired with its cosine similarity score.
class MemorySearchResult {
  const MemorySearchResult({
    required this.record,
    required this.score,
  });

  final MemoryRecord record;

  /// Cosine similarity score in range [-1, 1]. Higher is more similar.
  final double score;
}
