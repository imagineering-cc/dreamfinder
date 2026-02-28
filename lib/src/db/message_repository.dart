import 'database.dart';

/// Role of a persisted message.
enum MessageRole { user, assistant }

/// A persisted message row from the database.
class PersistedMessage {
  const PersistedMessage({
    required this.id,
    required this.chatId,
    required this.role,
    required this.content,
    this.senderUuid,
    this.senderName,
    required this.createdAt,
  });

  final int id;
  final String chatId;
  final MessageRole role;
  final String content;
  final String? senderUuid;
  final String? senderName;
  final String createdAt;
}

/// A conversation metadata row.
class ConversationInfo {
  const ConversationInfo({
    required this.chatId,
    required this.createdAt,
    required this.lastActivity,
  });

  final String chatId;
  final String createdAt;
  final String lastActivity;
}

/// Repository for persisting and querying messages and conversations.
class MessageRepository {
  MessageRepository(this._db);

  final BotDatabase _db;

  /// Persists a single message, auto-creating the conversation if needed.
  void saveMessage({
    required String chatId,
    required MessageRole role,
    required String content,
    String? senderUuid,
    String? senderName,
  }) {
    _ensureConversation(chatId);

    _db.handle.execute(
      'INSERT INTO messages (chat_id, role, content, sender_uuid, sender_name) '
      'VALUES (?, ?, ?, ?, ?)',
      [chatId, role.name, content, senderUuid, senderName],
    );

    _db.handle.execute(
      "UPDATE conversations SET last_activity = datetime('now') "
      'WHERE chat_id = ?',
      [chatId],
    );
  }

  /// Returns messages for [chatId] in chronological order.
  ///
  /// When [limit] is provided, returns the most recent [limit] messages
  /// (still in chronological order).
  List<PersistedMessage> getMessages({
    required String chatId,
    int? limit,
  }) {
    final String sql;
    final List<Object?> params;

    if (limit != null) {
      // Subquery to get the N most recent, then re-sort ascending.
      sql = 'SELECT * FROM ('
          'SELECT * FROM messages WHERE chat_id = ? ORDER BY id DESC LIMIT ?'
          ') ORDER BY id ASC';
      params = [chatId, limit];
    } else {
      sql = 'SELECT * FROM messages WHERE chat_id = ? ORDER BY id ASC';
      params = [chatId];
    }

    final result = _db.handle.select(sql, params);
    return [
      for (final row in result)
        PersistedMessage(
          id: row['id'] as int,
          chatId: row['chat_id'] as String,
          role:
              row['role'] == 'user' ? MessageRole.user : MessageRole.assistant,
          content: row['content'] as String,
          senderUuid: row['sender_uuid'] as String?,
          senderName: row['sender_name'] as String?,
          createdAt: row['created_at'] as String,
        ),
    ];
  }

  /// Deletes all messages and the conversation record for [chatId].
  void deleteConversation(String chatId) {
    _db.handle.execute('DELETE FROM messages WHERE chat_id = ?', [chatId]);
    _db.handle.execute('DELETE FROM conversations WHERE chat_id = ?', [chatId]);
  }

  /// Returns metadata for all conversations, ordered by most recently active.
  List<ConversationInfo> listConversations() {
    final result = _db.handle.select(
      'SELECT * FROM conversations ORDER BY last_activity DESC',
    );
    return [
      for (final row in result)
        ConversationInfo(
          chatId: row['chat_id'] as String,
          createdAt: row['created_at'] as String,
          lastActivity: row['last_activity'] as String,
        ),
    ];
  }

  /// Returns the total number of messages for [chatId].
  int messageCount(String chatId) {
    final result = _db.handle.select(
      'SELECT COUNT(*) as cnt FROM messages WHERE chat_id = ?',
      [chatId],
    );
    return result.first['cnt'] as int;
  }

  void _ensureConversation(String chatId) {
    _db.handle.execute(
      'INSERT OR IGNORE INTO conversations (chat_id) VALUES (?)',
      [chatId],
    );
  }
}
