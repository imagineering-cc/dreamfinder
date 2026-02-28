import 'package:imagineering_pm_bot/src/agent/conversation_history.dart';
import 'package:imagineering_pm_bot/src/db/database.dart';
import 'package:imagineering_pm_bot/src/db/message_repository.dart' as db_repo;
import 'package:imagineering_pm_bot/src/db/message_repository.dart'
    show MessageRepository;
import 'package:test/test.dart';

void main() {
  late ConversationHistory history;

  setUp(() {
    history =
        ConversationHistory(maxMessages: 6, ttl: const Duration(minutes: 30));
  });

  group('ConversationHistory', () {
    test('returns empty list for new chat', () {
      expect(history.getHistory('new'), isEmpty);
    });

    test('appends and retrieves messages', () {
      history.appendToHistory(
          'c1',
          const ChatMessage(role: MessageRole.user, content: 'Hello'),
          const ChatMessage(role: MessageRole.assistant, content: 'Hi!'));
      final msgs = history.getHistory('c1');
      expect(msgs, hasLength(2));
      expect(msgs[0].role, equals(MessageRole.user));
      expect(msgs[1].content, equals('Hi!'));
    });

    test('enforces sliding window', () {
      for (var i = 0; i < 4; i++) {
        history.appendToHistory(
            'c1',
            ChatMessage(role: MessageRole.user, content: 'msg $i'),
            ChatMessage(role: MessageRole.assistant, content: 'reply $i'));
      }
      final msgs = history.getHistory('c1');
      expect(msgs.length, lessThanOrEqualTo(6));
      expect(msgs.first.content, equals('msg 1'));
    });

    test('expires history after TTL', () {
      final short = ConversationHistory(maxMessages: 20, ttl: Duration.zero);
      short.appendToHistory(
          'c1',
          const ChatMessage(role: MessageRole.user, content: 'Hello'),
          const ChatMessage(role: MessageRole.assistant, content: 'Hi'));
      expect(short.getHistory('c1'), isEmpty);
    });

    test('clearHistory removes messages', () {
      history.appendToHistory(
          'c1',
          const ChatMessage(role: MessageRole.user, content: 'Hello'),
          const ChatMessage(role: MessageRole.assistant, content: 'Hi'));
      history.clearHistory('c1');
      expect(history.getHistory('c1'), isEmpty);
    });

    test('isolates history between chats', () {
      history.appendToHistory(
          'a',
          const ChatMessage(role: MessageRole.user, content: 'A'),
          const ChatMessage(role: MessageRole.assistant, content: 'A reply'));
      history.appendToHistory(
          'b',
          const ChatMessage(role: MessageRole.user, content: 'B'),
          const ChatMessage(role: MessageRole.assistant, content: 'B reply'));
      expect(history.getHistory('a'), hasLength(2));
      expect(history.getHistory('b'), hasLength(2));
      expect(history.getHistory('a').first.content, equals('A'));
      expect(history.getHistory('b').first.content, equals('B'));
    });
  });

  group('ConversationHistory with DB persistence', () {
    late BotDatabase db;
    late MessageRepository repo;
    late ConversationHistory dbHistory;

    setUp(() {
      db = BotDatabase.inMemory();
      repo = MessageRepository(db);
      dbHistory = ConversationHistory(
        maxMessages: 20,
        ttl: const Duration(minutes: 30),
        repository: repo,
      );
    });

    tearDown(() {
      db.close();
    });

    test('appendToHistory persists messages to DB', () {
      dbHistory.appendToHistory(
        'c1',
        const ChatMessage(role: MessageRole.user, content: 'Hello'),
        const ChatMessage(role: MessageRole.assistant, content: 'Hi!'),
      );

      // Verify messages were written to the database.
      final dbMessages = repo.getMessages(chatId: 'c1');
      expect(dbMessages, hasLength(2));
      expect(dbMessages[0].content, equals('Hello'));
      expect(dbMessages[1].content, equals('Hi!'));
    });

    test('getHistory loads from DB on cache miss', () {
      // Write directly to DB (simulating a previous session).
      repo.saveMessage(
        chatId: 'c1',
        role: db_repo.MessageRole.user,
        content: 'Previous session msg',
        senderUuid: 'u1',
      );
      repo.saveMessage(
        chatId: 'c1',
        role: db_repo.MessageRole.assistant,
        content: 'Previous session reply',
      );

      // The in-memory cache is empty, so getHistory should load from DB.
      final msgs = dbHistory.getHistory('c1');
      expect(msgs, hasLength(2));
      expect(msgs[0].content, equals('Previous session msg'));
      expect(msgs[1].content, equals('Previous session reply'));
    });

    test('getHistory reloads from DB after TTL expiry', () {
      final shortTtl = ConversationHistory(
        maxMessages: 20,
        ttl: Duration.zero,
        repository: repo,
      );

      // Populate the DB.
      repo.saveMessage(
        chatId: 'c1',
        role: db_repo.MessageRole.user,
        content: 'Persisted',
        senderUuid: 'u1',
      );
      repo.saveMessage(
        chatId: 'c1',
        role: db_repo.MessageRole.assistant,
        content: 'Also persisted',
      );

      // Even with TTL=0, the DB-backed history should reload.
      final msgs = shortTtl.getHistory('c1');
      expect(msgs, hasLength(2));
      expect(msgs[0].content, equals('Persisted'));
    });

    test('works without repository (backwards compatible)', () {
      final memOnly = ConversationHistory(maxMessages: 20);
      memOnly.appendToHistory(
        'c1',
        const ChatMessage(role: MessageRole.user, content: 'Hello'),
        const ChatMessage(role: MessageRole.assistant, content: 'Hi!'),
      );
      expect(memOnly.getHistory('c1'), hasLength(2));
    });

    test('respects maxMessages limit when loading from DB', () {
      // Write more messages to DB than maxMessages allows.
      for (var i = 0; i < 15; i++) {
        repo.saveMessage(
          chatId: 'c1',
          role: db_repo.MessageRole.user,
          content: 'msg $i',
          senderUuid: 'u1',
        );
        repo.saveMessage(
          chatId: 'c1',
          role: db_repo.MessageRole.assistant,
          content: 'reply $i',
        );
      }

      final limited = ConversationHistory(
        maxMessages: 6,
        repository: repo,
      );
      final msgs = limited.getHistory('c1');
      expect(msgs.length, lessThanOrEqualTo(6));
      // Should have the most recent messages.
      expect(msgs.last.content, equals('reply 14'));
    });
  });
}
