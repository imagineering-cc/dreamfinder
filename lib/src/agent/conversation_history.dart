/// Sliding-window conversation history per chat.
///
/// Keeps the last [maxMessages] messages per chat ID, evicting oldest
/// user/assistant pairs when the window overflows. Entries expire after
/// [ttl] of inactivity to avoid unbounded memory growth.
///
/// When a [MessageRepository] is provided, messages are persisted to SQLite
/// and reloaded on cache miss — so conversations survive restarts.
library;

import '../db/message_repository.dart' as db;

/// Role of a message in the conversation.
enum MessageRole { user, assistant }

/// A single message in the conversation history.
class ChatMessage {
  const ChatMessage({required this.role, required this.content});

  final MessageRole role;
  final String content;
}

class _ChatEntry {
  _ChatEntry({required this.messages, required this.lastActivity});

  final List<ChatMessage> messages;
  DateTime lastActivity;
}

/// In-memory conversation history with sliding window and TTL expiry.
///
/// Optionally backed by a [db.MessageRepository] for persistence.
class ConversationHistory {
  ConversationHistory({
    this.maxMessages = 20,
    this.ttl = const Duration(minutes: 30),
    db.MessageRepository? repository,
  }) : _repository = repository;

  final int maxMessages;
  final Duration ttl;
  final db.MessageRepository? _repository;
  final Map<String, _ChatEntry> _histories = {};

  List<ChatMessage> getHistory(String chatId) {
    final entry = _histories[chatId];
    if (entry != null && !_isExpired(entry)) {
      return List.unmodifiable(entry.messages);
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
        _histories[chatId] = _ChatEntry(
          messages: messages,
          lastActivity: DateTime.now(),
        );
        return List.unmodifiable(messages);
      }
    }

    return [];
  }

  void appendToHistory(
    String chatId,
    ChatMessage userMessage,
    ChatMessage assistantMessage,
  ) {
    // Persist to DB first (if available).
    if (_repository != null) {
      _repository.saveMessage(
        chatId: chatId,
        role: db.MessageRole.user,
        content: userMessage.content,
      );
      _repository.saveMessage(
        chatId: chatId,
        role: db.MessageRole.assistant,
        content: assistantMessage.content,
      );
    }

    final now = DateTime.now();
    var entry = _histories[chatId];
    if (entry == null || _isExpired(entry)) {
      entry = _ChatEntry(messages: [], lastActivity: now);
    }
    entry.messages.add(userMessage);
    entry.messages.add(assistantMessage);
    entry.lastActivity = now;

    while (entry.messages.length > maxMessages) {
      entry.messages.removeAt(0);
      if (entry.messages.isNotEmpty) {
        entry.messages.removeAt(0);
      }
    }
    _histories[chatId] = entry;
  }

  void clearHistory(String chatId) {
    _histories.remove(chatId);
  }

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
