import 'dart:convert';

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

  /// Plain [String] for text messages, or a deserialized JSON structure
  /// ([List] or [Map]) for tool-use / tool-result blocks.
  final Object content;

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

// ---------------------------------------------------------------------------
// Serialization helpers
// ---------------------------------------------------------------------------

/// Converts [content] to a string suitable for the TEXT column.
///
/// Plain strings are stored as-is; structured content (List/Map) is
/// JSON-encoded.
String serializeContent(Object content) {
  if (content is String) return content;
  return jsonEncode(content);
}

/// Reconstructs the original content from a raw DB string.
///
/// Strings that start with `[` or `{` are decoded as JSON; everything else
/// is returned as a plain string. On decode failure the raw string is
/// returned unchanged.
Object deserializeContent(String raw) {
  if (!raw.startsWith('[') && !raw.startsWith('{')) return raw;
  try {
    final parsed = jsonDecode(raw);
    if (parsed is List) {
      // Return a properly typed List<Map<String, dynamic>> so downstream
      // casts (e.g. in _callClaude) succeed.
      return <Map<String, dynamic>>[
        for (final item in parsed) Map<String, dynamic>.from(item as Map),
      ];
    }
    if (parsed is Map) return Map<String, dynamic>.from(parsed);
    return raw;
  } catch (_) {
    return raw;
  }
}

/// Truncates tool-result content strings that exceed [maxLength].
///
/// Only affects [List] content (tool-result blocks stored under user role).
/// Returns [content] unchanged for plain strings and maps.
Object truncateToolResultContent(Object content, {int maxLength = 1500}) {
  if (content is! List) return content;
  return <Map<String, dynamic>>[
    for (final item in content)
      if (item is Map<String, dynamic>)
        <String, dynamic>{
          ...item,
          'content': item['content'] is String &&
                  (item['content'] as String).length > maxLength
              ? '${(item['content'] as String).substring(0, maxLength)}'
                  '... [truncated]'
              : item['content'],
        }
      else
        Map<String, dynamic>.from(item as Map),
  ];
}

// ---------------------------------------------------------------------------
// Repository
// ---------------------------------------------------------------------------

/// Repository for persisting and querying messages and conversations.
class MessageRepository {
  MessageRepository(this._db);

  final BotDatabase _db;

  /// Persists a single message, auto-creating the conversation if needed.
  ///
  /// [content] may be a plain [String] or a structured object (List/Map) —
  /// it is serialised to JSON for storage.
  void saveMessage({
    required String chatId,
    required MessageRole role,
    required Object content,
    String? senderUuid,
    String? senderName,
  }) {
    _ensureConversation(chatId);

    _db.handle.execute(
      'INSERT INTO messages (chat_id, role, content, sender_uuid, sender_name) '
      'VALUES (?, ?, ?, ?, ?)',
      [chatId, role.name, serializeContent(content), senderUuid, senderName],
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
  /// (still in chronological order). Structured content is automatically
  /// deserialized from JSON.
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
          content: deserializeContent(row['content'] as String),
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

  /// Returns messages for [chatId] created after [since] (ISO 8601 datetime),
  /// in chronological order.
  ///
  /// Used by the dream cycle to replay chat history since the last cycle.
  List<PersistedMessage> getMessagesSince({
    required String chatId,
    required String since,
  }) {
    final result = _db.handle.select(
      'SELECT * FROM messages WHERE chat_id = ? AND created_at > ? '
      'ORDER BY id ASC',
      [chatId, since],
    );
    return [
      for (final row in result)
        PersistedMessage(
          id: row['id'] as int,
          chatId: row['chat_id'] as String,
          role:
              row['role'] == 'user' ? MessageRole.user : MessageRole.assistant,
          content: deserializeContent(row['content'] as String),
          senderUuid: row['sender_uuid'] as String?,
          senderName: row['sender_name'] as String?,
          createdAt: row['created_at'] as String,
        ),
    ];
  }

  /// Trims persisted messages to keep only the most recent [maxMessages].
  ///
  /// Uses the composite `idx_messages_chat_id_id` index for efficiency.
  void trimToWindow(String chatId, int maxMessages) {
    _db.handle.execute(
      'DELETE FROM messages WHERE chat_id = ? '
      'AND id NOT IN ('
      'SELECT id FROM messages WHERE chat_id = ? ORDER BY id DESC LIMIT ?'
      ')',
      [chatId, chatId, maxMessages],
    );
  }

  void _ensureConversation(String chatId) {
    _db.handle.execute(
      'INSERT OR IGNORE INTO conversations (chat_id) VALUES (?)',
      [chatId],
    );
  }
}
