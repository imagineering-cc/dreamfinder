import 'package:dreamfinder/src/db/database.dart';
import 'package:dreamfinder/src/db/message_repository.dart';
import 'package:test/test.dart';

void main() {
  late BotDatabase db;
  late MessageRepository repo;

  setUp(() {
    db = BotDatabase.inMemory();
    repo = MessageRepository(db);
  });

  tearDown(() {
    db.close();
  });

  group('MessageRepository', () {
    test('saveMessage persists a user message', () {
      repo.saveMessage(
        chatId: 'chat-1',
        role: MessageRole.user,
        content: 'Hello Dreamfinder!',
        senderUuid: 'uuid-abc',
        senderName: 'Alice',
      );

      final messages = repo.getMessages(chatId: 'chat-1');
      expect(messages, hasLength(1));
      expect(messages.first.content, equals('Hello Dreamfinder!'));
      expect(messages.first.role, equals(MessageRole.user));
      expect(messages.first.senderName, equals('Alice'));
    });

    test('saveMessage persists an assistant message', () {
      repo.saveMessage(
        chatId: 'chat-1',
        role: MessageRole.assistant,
        content: 'Hello! I am Dreamfinder.',
      );

      final messages = repo.getMessages(chatId: 'chat-1');
      expect(messages, hasLength(1));
      expect(messages.first.role, equals(MessageRole.assistant));
      expect(messages.first.senderUuid, isNull);
    });

    test('getMessages returns messages in chronological order', () {
      repo.saveMessage(
        chatId: 'chat-1',
        role: MessageRole.user,
        content: 'First',
        senderUuid: 'u1',
      );
      repo.saveMessage(
        chatId: 'chat-1',
        role: MessageRole.assistant,
        content: 'Second',
      );
      repo.saveMessage(
        chatId: 'chat-1',
        role: MessageRole.user,
        content: 'Third',
        senderUuid: 'u1',
      );

      final messages = repo.getMessages(chatId: 'chat-1');
      expect(messages, hasLength(3));
      expect(messages[0].content, equals('First'));
      expect(messages[1].content, equals('Second'));
      expect(messages[2].content, equals('Third'));
    });

    test('getMessages respects limit parameter', () {
      for (var i = 0; i < 10; i++) {
        repo.saveMessage(
          chatId: 'chat-1',
          role: MessageRole.user,
          content: 'Message $i',
          senderUuid: 'u1',
        );
      }

      final messages = repo.getMessages(chatId: 'chat-1', limit: 3);
      expect(messages, hasLength(3));
      // Should return the 3 most recent, in chronological order.
      expect(messages[0].content, equals('Message 7'));
      expect(messages[1].content, equals('Message 8'));
      expect(messages[2].content, equals('Message 9'));
    });

    test('getMessages isolates conversations by chatId', () {
      repo.saveMessage(
        chatId: 'chat-a',
        role: MessageRole.user,
        content: 'In chat A',
        senderUuid: 'u1',
      );
      repo.saveMessage(
        chatId: 'chat-b',
        role: MessageRole.user,
        content: 'In chat B',
        senderUuid: 'u2',
      );

      expect(repo.getMessages(chatId: 'chat-a'), hasLength(1));
      expect(repo.getMessages(chatId: 'chat-b'), hasLength(1));
      expect(
        repo.getMessages(chatId: 'chat-a').first.content,
        equals('In chat A'),
      );
    });

    test('getMessages returns empty list for unknown chatId', () {
      expect(repo.getMessages(chatId: 'nonexistent'), isEmpty);
    });

    test('deleteConversation removes all messages for a chat', () {
      repo.saveMessage(
        chatId: 'chat-1',
        role: MessageRole.user,
        content: 'Hello',
        senderUuid: 'u1',
      );
      repo.saveMessage(
        chatId: 'chat-1',
        role: MessageRole.assistant,
        content: 'Hi!',
      );
      repo.saveMessage(
        chatId: 'chat-2',
        role: MessageRole.user,
        content: 'Other chat',
        senderUuid: 'u2',
      );

      repo.deleteConversation('chat-1');

      expect(repo.getMessages(chatId: 'chat-1'), isEmpty);
      expect(repo.getMessages(chatId: 'chat-2'), hasLength(1));
    });

    test('auto-creates conversation record on first message', () {
      repo.saveMessage(
        chatId: 'new-chat',
        role: MessageRole.user,
        content: 'Hello',
        senderUuid: 'u1',
      );

      // The conversation row should exist.
      final conversations = repo.listConversations();
      expect(conversations.map((c) => c.chatId), contains('new-chat'));
    });

    test('listConversations returns all active conversations', () {
      repo.saveMessage(
        chatId: 'chat-a',
        role: MessageRole.user,
        content: 'A',
        senderUuid: 'u1',
      );
      repo.saveMessage(
        chatId: 'chat-b',
        role: MessageRole.user,
        content: 'B',
        senderUuid: 'u2',
      );

      final conversations = repo.listConversations();
      expect(conversations, hasLength(2));
    });

    test('getMessagesSince returns messages after a given timestamp', () {
      // Insert messages with explicit timestamps via raw SQL.
      db.handle.execute(
        'INSERT OR IGNORE INTO conversations (chat_id) VALUES (?)',
        ['chat-1'],
      );
      db.handle.execute(
        'INSERT INTO messages (chat_id, role, content, sender_uuid, '
        "sender_name, created_at) VALUES (?, 'user', ?, ?, ?, ?)",
        ['chat-1', 'Old message', 'u1', 'Alice', '2026-03-13T10:00:00'],
      );
      db.handle.execute(
        'INSERT INTO messages (chat_id, role, content, sender_uuid, '
        "sender_name, created_at) VALUES (?, 'user', ?, ?, ?, ?)",
        ['chat-1', 'New message', 'u1', 'Alice', '2026-03-14T10:00:00'],
      );
      db.handle.execute(
        'INSERT INTO messages (chat_id, role, content, sender_uuid, '
        "sender_name, created_at) VALUES (?, 'assistant', ?, NULL, NULL, ?)",
        ['chat-1', 'Response to new', '2026-03-14T10:01:00'],
      );

      final messages = repo.getMessagesSince(
        chatId: 'chat-1',
        since: '2026-03-13T23:00:00',
      );

      expect(messages, hasLength(2));
      expect(messages[0].content, equals('New message'));
      expect(messages[1].content, equals('Response to new'));
    });

    test('getMessagesSince returns empty list when no messages after since',
        () {
      repo.saveMessage(
        chatId: 'chat-1',
        role: MessageRole.user,
        content: 'Old',
        senderUuid: 'u1',
      );

      final messages = repo.getMessagesSince(
        chatId: 'chat-1',
        since: '2099-01-01T00:00:00',
      );

      expect(messages, isEmpty);
    });

    test('messageCount returns total messages for a chat', () {
      repo.saveMessage(
        chatId: 'chat-1',
        role: MessageRole.user,
        content: 'One',
        senderUuid: 'u1',
      );
      repo.saveMessage(
        chatId: 'chat-1',
        role: MessageRole.assistant,
        content: 'Two',
      );

      expect(repo.messageCount('chat-1'), equals(2));
      expect(repo.messageCount('nonexistent'), equals(0));
    });
  });
}
