import 'dart:convert';

import 'package:dreamfinder/src/agent/conversation_history.dart';
import 'package:dreamfinder/src/db/database.dart';
import 'package:dreamfinder/src/db/message_repository.dart' as db_repo;
import 'package:dreamfinder/src/db/message_repository.dart'
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
      history.appendTurn('c1', const [
        ChatMessage(role: MessageRole.user, content: 'Hello'),
        ChatMessage(role: MessageRole.assistant, content: 'Hi!'),
      ]);
      final msgs = history.getHistory('c1');
      expect(msgs, hasLength(2));
      expect(msgs[0].role, equals(MessageRole.user));
      expect(msgs[1].content, equals('Hi!'));
    });

    test('enforces sliding window', () {
      for (var i = 0; i < 4; i++) {
        history.appendTurn('c1', [
          ChatMessage(role: MessageRole.user, content: 'msg $i'),
          ChatMessage(role: MessageRole.assistant, content: 'reply $i'),
        ]);
      }
      final msgs = history.getHistory('c1');
      expect(msgs.length, lessThanOrEqualTo(6));
      expect(msgs.first.content, equals('msg 1'));
    });

    test('expires history after TTL', () {
      final short = ConversationHistory(maxMessages: 40, ttl: Duration.zero);
      short.appendTurn('c1', const [
        ChatMessage(role: MessageRole.user, content: 'Hello'),
        ChatMessage(role: MessageRole.assistant, content: 'Hi'),
      ]);
      expect(short.getHistory('c1'), isEmpty);
    });

    test('clearHistory removes messages', () {
      history.appendTurn('c1', const [
        ChatMessage(role: MessageRole.user, content: 'Hello'),
        ChatMessage(role: MessageRole.assistant, content: 'Hi'),
      ]);
      history.clearHistory('c1');
      expect(history.getHistory('c1'), isEmpty);
    });

    test('isolates history between chats', () {
      history.appendTurn('a', const [
        ChatMessage(role: MessageRole.user, content: 'A'),
        ChatMessage(role: MessageRole.assistant, content: 'A reply'),
      ]);
      history.appendTurn('b', const [
        ChatMessage(role: MessageRole.user, content: 'B'),
        ChatMessage(role: MessageRole.assistant, content: 'B reply'),
      ]);
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
        maxMessages: 40,
        ttl: const Duration(minutes: 30),
        repository: repo,
      );
    });

    tearDown(() {
      db.close();
    });

    test('appendTurn persists messages to DB', () {
      dbHistory.appendTurn('c1', const [
        ChatMessage(role: MessageRole.user, content: 'Hello'),
        ChatMessage(role: MessageRole.assistant, content: 'Hi!'),
      ]);

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
        maxMessages: 40,
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
      final memOnly = ConversationHistory(maxMessages: 40);
      memOnly.appendTurn('c1', const [
        ChatMessage(role: MessageRole.user, content: 'Hello'),
        ChatMessage(role: MessageRole.assistant, content: 'Hi!'),
      ]);
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

  group('Structured content', () {
    late BotDatabase db;
    late MessageRepository repo;
    late ConversationHistory dbHistory;

    // A complete tool-call turn: user text → assistant+tool_use →
    // tool_result → assistant text.
    final toolTurn = [
      const ChatMessage(role: MessageRole.user, content: 'Create a card'),
      const ChatMessage(
        role: MessageRole.assistant,
        content: <String, dynamic>{
          'textBlocks': <Map<String, String>>[],
          'toolUseBlocks': <Map<String, dynamic>>[
            {'id': 't1', 'name': 'kan_create_card', 'input': <String, dynamic>{'title': 'Test'}},
          ],
        },
      ),
      const ChatMessage(
        role: MessageRole.user,
        content: <Map<String, dynamic>>[
          {'toolUseId': 't1', 'content': '{"id": "card-1"}', 'isError': false},
        ],
      ),
      const ChatMessage(
          role: MessageRole.assistant, content: 'I created the card "Test".'),
    ];

    setUp(() {
      db = BotDatabase.inMemory();
      repo = MessageRepository(db);
      dbHistory = ConversationHistory(
        maxMessages: 40,
        ttl: const Duration(minutes: 30),
        repository: repo,
      );
    });

    tearDown(() {
      db.close();
    });

    test('preserves tool call round-trip in history', () {
      dbHistory.appendTurn('c1', toolTurn);
      final msgs = dbHistory.getHistory('c1');

      expect(msgs, hasLength(4));
      expect(msgs[0].content, equals('Create a card'));
      expect(msgs[1].content, isA<Map<String, dynamic>>());
      expect(msgs[2].content, isA<List<Map<String, dynamic>>>());
      expect(msgs[3].content, equals('I created the card "Test".'));
    });

    test('serializes structured content to DB as JSON', () {
      dbHistory.appendTurn('c1', toolTurn);

      // Read raw DB rows to verify JSON storage.
      final rows = db.handle.select(
          'SELECT content FROM messages WHERE chat_id = ? ORDER BY id ASC',
          ['c1']);
      expect(rows, hasLength(4));

      // User text → plain string.
      expect(rows[0]['content'], equals('Create a card'));

      // Assistant + tool_use → JSON object.
      final assistantRaw = rows[1]['content'] as String;
      expect(assistantRaw, startsWith('{'));
      final assistantDecoded =
          jsonDecode(assistantRaw) as Map<String, dynamic>;
      expect(assistantDecoded, contains('toolUseBlocks'));

      // Tool result → JSON array.
      final toolResultRaw = rows[2]['content'] as String;
      expect(toolResultRaw, startsWith('['));

      // Final assistant text → plain string.
      expect(rows[3]['content'], equals('I created the card "Test".'));
    });

    test('deserializes structured content from DB on cache miss', () {
      dbHistory.appendTurn('c1', toolTurn);

      // Force cache miss.
      dbHistory.clearHistory('c1');

      final msgs = dbHistory.getHistory('c1');
      expect(msgs, hasLength(4));

      // Verify structured types survived the round-trip.
      expect(msgs[0].content, isA<String>());
      expect(msgs[1].content, isA<Map<String, dynamic>>());
      expect(msgs[2].content, isA<List<dynamic>>());
      expect(msgs[3].content, isA<String>());

      // Verify tool_result block contents.
      final toolResult = msgs[2].content as List<dynamic>;
      expect(toolResult.first, isA<Map<String, dynamic>>());
      expect(
          (toolResult.first as Map<String, dynamic>)['toolUseId'], equals('t1'));
    });

    test('truncates large tool results in DB only', () {
      final largeTurn = [
        const ChatMessage(role: MessageRole.user, content: 'Search boards'),
        const ChatMessage(
          role: MessageRole.assistant,
          content: <String, dynamic>{
            'textBlocks': <Map<String, String>>[],
            'toolUseBlocks': <Map<String, dynamic>>[
              {'id': 't2', 'name': 'kan_list_boards', 'input': <String, dynamic>{}},
            ],
          },
        ),
        ChatMessage(
          role: MessageRole.user,
          content: <Map<String, dynamic>>[
            {
              'toolUseId': 't2',
              'content': 'x' * 3000, // 3000 chars — exceeds 1500 limit
              'isError': false,
            },
          ],
        ),
        const ChatMessage(
            role: MessageRole.assistant, content: 'Found 10 boards.'),
      ];

      dbHistory.appendTurn('c1', largeTurn);

      // In-memory should have the full content.
      final memMsgs = dbHistory.getHistory('c1');
      final memToolResult = memMsgs[2].content as List;
      expect(
        (memToolResult.first as Map)['content'],
        hasLength(3000),
      );

      // DB should have truncated content.
      final rows = db.handle.select(
        "SELECT content FROM messages WHERE chat_id = 'c1' AND role = 'user' "
        'ORDER BY id ASC',
      );
      // Second user-role message is the tool_result.
      final dbToolResult =
          jsonDecode(rows[1]['content'] as String) as List;
      final dbContent = (dbToolResult.first as Map)['content'] as String;
      expect(dbContent.length, lessThan(3000));
      expect(dbContent, contains('[truncated]'));
    });

    test('evicts complete turns, never orphaning tool blocks', () {
      // maxMessages = 6, each tool turn = 4 messages.
      // After 2 tool turns (8 messages), oldest turn should be evicted.
      final smallHistory = ConversationHistory(maxMessages: 6);

      smallHistory.appendTurn('c1', [
        const ChatMessage(role: MessageRole.user, content: 'Turn 1'),
        const ChatMessage(
          role: MessageRole.assistant,
          content: <String, dynamic>{
            'textBlocks': <Map<String, String>>[],
            'toolUseBlocks': <Map<String, dynamic>>[
              {'id': 't1', 'name': 'tool', 'input': <String, dynamic>{}},
            ],
          },
        ),
        const ChatMessage(
          role: MessageRole.user,
          content: <Map<String, dynamic>>[
            {'toolUseId': 't1', 'content': 'result1', 'isError': false},
          ],
        ),
        const ChatMessage(role: MessageRole.assistant, content: 'Done 1'),
      ]);

      smallHistory.appendTurn('c1', [
        const ChatMessage(role: MessageRole.user, content: 'Turn 2'),
        const ChatMessage(
          role: MessageRole.assistant,
          content: <String, dynamic>{
            'textBlocks': <Map<String, String>>[],
            'toolUseBlocks': <Map<String, dynamic>>[
              {'id': 't2', 'name': 'tool', 'input': <String, dynamic>{}},
            ],
          },
        ),
        const ChatMessage(
          role: MessageRole.user,
          content: <Map<String, dynamic>>[
            {'toolUseId': 't2', 'content': 'result2', 'isError': false},
          ],
        ),
        const ChatMessage(role: MessageRole.assistant, content: 'Done 2'),
      ]);

      final msgs = smallHistory.getHistory('c1');

      // Should have evicted Turn 1 (4 msgs) and kept Turn 2 (4 msgs).
      // With maxMessages=6 and 2 turns of 4 msgs each (8 total), we
      // evict the first turn leaving 4 messages.
      expect(msgs.length, lessThanOrEqualTo(6));
      // Verify no orphaned fragments — first message should start a turn.
      expect(msgs.first.content, equals('Turn 2'));
      expect(msgs.first.role, equals(MessageRole.user));
    });

    test('backward compatible with plain text DB rows', () {
      // Simulate old-format DB rows (plain text only).
      repo.saveMessage(
        chatId: 'c1',
        role: db_repo.MessageRole.user,
        content: 'Old format question',
        senderUuid: 'u1',
      );
      repo.saveMessage(
        chatId: 'c1',
        role: db_repo.MessageRole.assistant,
        content: 'Old format answer',
      );

      final msgs = dbHistory.getHistory('c1');
      expect(msgs, hasLength(2));
      expect(msgs[0].content, isA<String>());
      expect(msgs[0].content, equals('Old format question'));
      expect(msgs[1].content, equals('Old format answer'));
    });

    test('trims orphaned tool_result at start on DB load', () {
      // Simulate a DB window that starts mid-turn (orphaned tool_result).
      repo.saveMessage(
        chatId: 'c1',
        role: db_repo.MessageRole.user,
        content: jsonEncode([
          {'toolUseId': 't0', 'content': 'orphan', 'isError': false},
        ]),
      );
      repo.saveMessage(
        chatId: 'c1',
        role: db_repo.MessageRole.assistant,
        content: 'Orphaned response',
      );
      repo.saveMessage(
        chatId: 'c1',
        role: db_repo.MessageRole.user,
        content: 'Valid turn start',
        senderUuid: 'u1',
      );
      repo.saveMessage(
        chatId: 'c1',
        role: db_repo.MessageRole.assistant,
        content: 'Valid reply',
      );

      final msgs = dbHistory.getHistory('c1');

      // The orphaned tool_result + its response should be trimmed.
      expect(msgs, hasLength(2));
      expect(msgs[0].content, equals('Valid turn start'));
      expect(msgs[1].content, equals('Valid reply'));
    });
  });

  group('trimToValidBoundaries', () {
    test('passes through clean message list unchanged', () {
      final messages = [
        const ChatMessage(role: MessageRole.user, content: 'Hi'),
        const ChatMessage(role: MessageRole.assistant, content: 'Hello'),
      ];
      expect(trimToValidBoundaries(messages), hasLength(2));
    });

    test('strips orphaned assistant at start', () {
      final messages = [
        const ChatMessage(role: MessageRole.assistant, content: 'Orphan'),
        const ChatMessage(role: MessageRole.user, content: 'Valid'),
        const ChatMessage(role: MessageRole.assistant, content: 'Reply'),
      ];
      final result = trimToValidBoundaries(messages);
      expect(result, hasLength(2));
      expect(result.first.content, equals('Valid'));
    });

    test('returns empty for all-orphan messages', () {
      final messages = [
        const ChatMessage(
          role: MessageRole.user,
          content: <Map<String, dynamic>>[
            {'toolUseId': 't1', 'content': 'result', 'isError': false},
          ],
        ),
        const ChatMessage(role: MessageRole.assistant, content: 'Done'),
      ];
      expect(trimToValidBoundaries(messages), isEmpty);
    });

    test('handles empty list', () {
      expect(trimToValidBoundaries([]), isEmpty);
    });
  });

  group('reconstructTurns', () {
    test('groups simple text turns', () {
      final messages = [
        const ChatMessage(role: MessageRole.user, content: 'Q1'),
        const ChatMessage(role: MessageRole.assistant, content: 'A1'),
        const ChatMessage(role: MessageRole.user, content: 'Q2'),
        const ChatMessage(role: MessageRole.assistant, content: 'A2'),
      ];
      final turns = reconstructTurns(messages);
      expect(turns, hasLength(2));
      expect(turns[0], hasLength(2));
      expect(turns[1], hasLength(2));
    });

    test('groups tool-call turn as single unit', () {
      final messages = [
        const ChatMessage(role: MessageRole.user, content: 'Do it'),
        const ChatMessage(
          role: MessageRole.assistant,
          content: <String, dynamic>{
            'textBlocks': <Map<String, String>>[],
            'toolUseBlocks': <Map<String, dynamic>>[
              {'id': 't1', 'name': 'tool', 'input': <String, dynamic>{}},
            ],
          },
        ),
        const ChatMessage(
          role: MessageRole.user,
          content: <Map<String, dynamic>>[
            {'toolUseId': 't1', 'content': 'ok', 'isError': false},
          ],
        ),
        const ChatMessage(role: MessageRole.assistant, content: 'Done'),
      ];
      final turns = reconstructTurns(messages);
      expect(turns, hasLength(1));
      expect(turns[0], hasLength(4));
    });

    test('handles empty list', () {
      expect(reconstructTurns([]), isEmpty);
    });
  });
}
