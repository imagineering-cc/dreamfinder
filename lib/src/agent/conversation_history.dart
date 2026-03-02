/// Turn-based conversation history per chat.
///
/// Stores complete turns (user text → tool calls → final response) as atomic
/// units. When the sliding window overflows, entire turns are evicted —
/// preventing orphaned tool_use / tool_result blocks that would cause Claude
/// API errors.
///
/// When a [MessageRepository] is provided, messages are persisted to SQLite
/// and reloaded on cache miss — so conversations survive restarts.
library;

import '../db/message_repository.dart' as db;

/// Role of a message in the conversation.
enum MessageRole { user, assistant }

/// A single message in the conversation history.
///
/// [content] is a plain [String] for text messages, or a structured object
/// ([List<Map>] for tool-result blocks, [Map] for assistant+tool-use blocks).
class ChatMessage {
  const ChatMessage({required this.role, required this.content});

  final MessageRole role;
  final Object content;
}

class _ChatEntry {
  _ChatEntry({required this.turns, required this.lastActivity});

  /// Each inner list is one complete turn (user text through final assistant
  /// response, including any intermediate tool_use / tool_result pairs).
  final List<List<ChatMessage>> turns;
  DateTime lastActivity;
}

/// In-memory conversation history with turn-based sliding window and TTL
/// expiry.
///
/// Optionally backed by a [db.MessageRepository] for persistence.
class ConversationHistory {
  ConversationHistory({
    this.maxMessages = 40,
    this.ttl = const Duration(minutes: 30),
    db.MessageRepository? repository,
  }) : _repository = repository;

  final int maxMessages;
  final Duration ttl;
  final db.MessageRepository? _repository;
  final Map<String, _ChatEntry> _histories = {};

  /// Returns the conversation history as a flat list of [ChatMessage]s.
  ///
  /// On cache miss (or TTL expiry), reloads from the database, trims orphaned
  /// fragments, and reconstructs turn boundaries.
  List<ChatMessage> getHistory(String chatId) {
    final entry = _histories[chatId];
    if (entry != null && !_isExpired(entry)) {
      final flat = entry.turns.expand((t) => t).toList();
      return List.unmodifiable(flat);
    }

    // Cache miss or expired — try loading from DB.
    _histories.remove(chatId);
    if (_repository != null) {
      final persisted =
          _repository.getMessages(chatId: chatId, limit: maxMessages);
      if (persisted.isNotEmpty) {
        final messages = <ChatMessage>[
          for (final m in persisted)
            ChatMessage(
              role: m.role == db.MessageRole.user
                  ? MessageRole.user
                  : MessageRole.assistant,
              content: m.content,
            ),
        ];
        final trimmed = trimToValidBoundaries(messages);
        final turns = reconstructTurns(trimmed);
        _histories[chatId] = _ChatEntry(
          turns: turns,
          lastActivity: DateTime.now(),
        );
        return List.unmodifiable(trimmed);
      }
    }

    return [];
  }

  /// Appends a complete turn to the history for [chatId].
  ///
  /// A turn is the full message chain from a single user request:
  /// `[user_text, assistant+tool_use, tool_result, ..., assistant_text]`.
  ///
  /// Persists to the database (with truncated tool results) and evicts oldest
  /// complete turns when the total message count exceeds [maxMessages].
  void appendTurn(String chatId, List<ChatMessage> turnMessages) {
    // Persist to DB with truncated tool results.
    if (_repository != null) {
      for (final msg in turnMessages) {
        final content = msg.role == MessageRole.user && msg.content is List
            ? db.truncateToolResultContent(msg.content)
            : msg.content;
        _repository.saveMessage(
          chatId: chatId,
          role: msg.role == MessageRole.user
              ? db.MessageRole.user
              : db.MessageRole.assistant,
          content: content,
        );
      }
      _repository.trimToWindow(chatId, maxMessages);
    }

    final now = DateTime.now();
    var entry = _histories[chatId];
    if (entry == null || _isExpired(entry)) {
      entry = _ChatEntry(turns: [], lastActivity: now);
    }
    entry.turns.add(turnMessages);
    entry.lastActivity = now;

    // Evict oldest complete turns while total message count > maxMessages.
    var totalMessages = entry.turns.fold<int>(0, (sum, t) => sum + t.length);
    while (totalMessages > maxMessages && entry.turns.length > 1) {
      totalMessages -= entry.turns.removeAt(0).length;
    }

    _histories[chatId] = entry;
  }

  /// Removes the in-memory cache entry for [chatId].
  void clearHistory(String chatId) {
    _histories.remove(chatId);
  }

  /// Removes all expired entries from the in-memory cache.
  void evictStale() {
    final now = DateTime.now();
    _histories.removeWhere(
      (_, entry) => now.difference(entry.lastActivity) > ttl,
    );
  }

  bool _isExpired(_ChatEntry entry) {
    return DateTime.now().difference(entry.lastActivity) > ttl;
  }
}

// ---------------------------------------------------------------------------
// Turn boundary helpers
// ---------------------------------------------------------------------------

/// Strips orphaned fragments at the start of a message window.
///
/// When loading from DB with a LIMIT, the window may start mid-turn (e.g.
/// with a tool_result block). This trims forward until a user message with
/// plain [String] content (a new turn boundary) is found.
List<ChatMessage> trimToValidBoundaries(List<ChatMessage> messages) {
  if (messages.isEmpty) return messages;

  var start = 0;
  while (start < messages.length) {
    final msg = messages[start];
    if (msg.role == MessageRole.user && msg.content is String) break;
    start++;
  }

  if (start >= messages.length) return [];
  return messages.sublist(start);
}

/// Groups a flat list of messages into turns.
///
/// A new turn starts at each user message with plain [String] content.
/// User messages with [List] content (tool_result blocks) are mid-turn
/// continuations.
List<List<ChatMessage>> reconstructTurns(List<ChatMessage> messages) {
  if (messages.isEmpty) return [];

  final turns = <List<ChatMessage>>[];
  var currentTurn = <ChatMessage>[];

  for (final msg in messages) {
    // A user message with String content marks the start of a new turn.
    if (msg.role == MessageRole.user &&
        msg.content is String &&
        currentTurn.isNotEmpty) {
      turns.add(currentTurn);
      currentTurn = <ChatMessage>[];
    }
    currentTurn.add(msg);
  }

  if (currentTurn.isNotEmpty) {
    turns.add(currentTurn);
  }

  return turns;
}
