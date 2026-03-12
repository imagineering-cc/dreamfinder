import 'package:dreamfinder/src/db/database.dart';
import 'package:dreamfinder/src/db/queries/memory_queries.dart';
import 'package:dreamfinder/src/memory/memory_record.dart';
import 'package:test/test.dart';

/// Test-only accessor that mixes in MemoryQueries.
class TestMemoryQueries with MemoryQueries {
  TestMemoryQueries(this.db);

  @override
  final BotDatabase db;
}

void main() {
  late BotDatabase database;
  late TestMemoryQueries queries;

  setUp(() {
    database = BotDatabase.inMemory();
    queries = TestMemoryQueries(database);
  });

  tearDown(() {
    database.close();
  });

  group('insertMemoryEmbedding', () {
    test('inserts a record and returns its ID', () {
      final id = queries.insertMemoryEmbedding(
        chatId: 'group-1',
        sourceType: MemorySourceType.message,
        sourceText: 'Test conversation text',
        senderUuid: 'uuid-1',
        senderName: 'Nick',
      );

      expect(id, greaterThan(0));
      expect(queries.countMemoryEmbeddings(), equals(1));
    });

    test('stores and retrieves embedding blob correctly', () {
      final embedding = List.generate(512, (i) => i * 0.001);

      queries.insertMemoryEmbedding(
        chatId: 'group-1',
        sourceType: MemorySourceType.message,
        sourceText: 'Test text',
        embedding: embedding,
      );

      final records = queries.getEmbeddedMemories(chatId: 'group-1');
      expect(records, hasLength(1));
      expect(records.first.embedding, isNotNull);
      expect(records.first.embedding!.length, equals(512));

      // Verify values survive the float32 roundtrip (some precision loss OK).
      for (var i = 0; i < 10; i++) {
        expect(records.first.embedding![i], closeTo(embedding[i], 0.0001));
      }
    });

    test('inserts record without embedding (null blob)', () {
      queries.insertMemoryEmbedding(
        chatId: 'group-1',
        sourceType: MemorySourceType.message,
        sourceText: 'Pending embedding',
      );

      // getEmbeddedMemories filters for non-null embeddings.
      final embedded = queries.getEmbeddedMemories(chatId: 'group-1');
      expect(embedded, isEmpty);

      // But count includes all records.
      expect(queries.countMemoryEmbeddings(), equals(1));
    });
  });

  group('updateMemoryEmbedding', () {
    test('adds embedding to an existing record', () {
      final id = queries.insertMemoryEmbedding(
        chatId: 'group-1',
        sourceType: MemorySourceType.message,
        sourceText: 'Will be embedded later',
      );

      final embedding = List.filled(512, 0.5);
      queries.updateMemoryEmbedding(id, embedding);

      final records = queries.getEmbeddedMemories(chatId: 'group-1');
      expect(records, hasLength(1));
      expect(records.first.embedding![0], closeTo(0.5, 0.001));
    });
  });

  group('getVisibleMemories', () {
    test('returns same_chat records for matching chat', () {
      queries.insertMemoryEmbedding(
        chatId: 'group-1',
        sourceType: MemorySourceType.message,
        sourceText: 'Group 1 memory',
        visibility: MemoryVisibility.sameChat,
        embedding: List.filled(512, 0.1),
      );
      queries.insertMemoryEmbedding(
        chatId: 'group-2',
        sourceType: MemorySourceType.message,
        sourceText: 'Group 2 memory',
        visibility: MemoryVisibility.sameChat,
        embedding: List.filled(512, 0.2),
      );

      final visible = queries.getVisibleMemories('group-1');
      expect(visible, hasLength(1));
      expect(visible.first.chatId, equals('group-1'));
    });

    test('includes cross_chat records from any chat', () {
      queries.insertMemoryEmbedding(
        chatId: 'group-2',
        sourceType: MemorySourceType.message,
        sourceText: 'Shared knowledge',
        visibility: MemoryVisibility.crossChat,
        embedding: List.filled(512, 0.1),
      );

      final visible = queries.getVisibleMemories('group-1');
      expect(visible, hasLength(1));
      expect(visible.first.sourceText, equals('Shared knowledge'));
    });

    test('excludes private records from other chats', () {
      queries.insertMemoryEmbedding(
        chatId: 'dm-alice',
        sourceType: MemorySourceType.message,
        sourceText: 'Private DM with Alice',
        visibility: MemoryVisibility.private_,
        embedding: List.filled(512, 0.1),
      );

      final visible = queries.getVisibleMemories('dm-bob');
      expect(visible, isEmpty);
    });

    test('includes private records from same chat', () {
      queries.insertMemoryEmbedding(
        chatId: 'dm-alice',
        sourceType: MemorySourceType.message,
        sourceText: 'Private DM with Alice',
        visibility: MemoryVisibility.private_,
        embedding: List.filled(512, 0.1),
      );

      final visible = queries.getVisibleMemories('dm-alice');
      expect(visible, hasLength(1));
    });
  });

  group('consolidation state', () {
    test('returns 0 for unknown chat', () {
      expect(queries.getLastConsolidatedId('unknown'), equals(0));
    });

    test('stores and retrieves last consolidated ID', () {
      queries.setLastConsolidatedId('group-1', 42);
      expect(queries.getLastConsolidatedId('group-1'), equals(42));
    });

    test('updates existing consolidation state', () {
      queries.setLastConsolidatedId('group-1', 10);
      queries.setLastConsolidatedId('group-1', 50);
      expect(queries.getLastConsolidatedId('group-1'), equals(50));
    });
  });

  group('getChatsWithUnconsolidatedMemories', () {
    test('returns distinct chat IDs with message-type embeddings', () {
      queries.insertMemoryEmbedding(
        chatId: 'group-1',
        sourceType: MemorySourceType.message,
        sourceText: 'Text 1',
      );
      queries.insertMemoryEmbedding(
        chatId: 'group-2',
        sourceType: MemorySourceType.message,
        sourceText: 'Text 2',
      );
      // Summary-type should not appear.
      queries.insertMemoryEmbedding(
        chatId: 'group-3',
        sourceType: MemorySourceType.summary,
        sourceText: 'Summary',
      );

      final chats = queries.getChatsWithUnconsolidatedMemories();
      expect(chats, containsAll(['group-1', 'group-2']));
      expect(chats, isNot(contains('group-3')));
    });

    test('returns empty list when no message embeddings exist', () {
      final chats = queries.getChatsWithUnconsolidatedMemories();
      expect(chats, isEmpty);
    });
  });

  group('getUnconsolidatedMemories', () {
    test('respects afterId filter', () {
      final id1 = queries.insertMemoryEmbedding(
        chatId: 'group-1',
        sourceType: MemorySourceType.message,
        sourceText: 'Old message',
      );
      queries.insertMemoryEmbedding(
        chatId: 'group-1',
        sourceType: MemorySourceType.message,
        sourceText: 'New message',
      );
      // Backdate both records so they pass the age filter.
      database.handle.execute(
        "UPDATE memory_embeddings SET created_at = datetime('now', '-72 hours')",
      );

      final memories = queries.getUnconsolidatedMemories(
        'group-1',
        afterId: id1,
        minAgeHours: 48,
      );
      expect(memories, hasLength(1));
      expect(memories.first.sourceText, equals('New message'));
    });

    test('respects age filter', () {
      queries.insertMemoryEmbedding(
        chatId: 'group-1',
        sourceType: MemorySourceType.message,
        sourceText: 'Recent message',
      );
      queries.insertMemoryEmbedding(
        chatId: 'group-1',
        sourceType: MemorySourceType.message,
        sourceText: 'Old message',
      );
      // Only backdate the second record.
      database.handle.execute(
        "UPDATE memory_embeddings SET created_at = datetime('now', '-72 hours') "
        "WHERE source_text = 'Old message'",
      );

      final memories = queries.getUnconsolidatedMemories(
        'group-1',
        afterId: 0,
        minAgeHours: 48,
      );
      expect(memories, hasLength(1));
      expect(memories.first.sourceText, equals('Old message'));
    });

    test('only returns message-type records', () {
      queries.insertMemoryEmbedding(
        chatId: 'group-1',
        sourceType: MemorySourceType.message,
        sourceText: 'Message',
      );
      queries.insertMemoryEmbedding(
        chatId: 'group-1',
        sourceType: MemorySourceType.summary,
        sourceText: 'Summary',
      );
      database.handle.execute(
        "UPDATE memory_embeddings SET created_at = datetime('now', '-72 hours')",
      );

      final memories = queries.getUnconsolidatedMemories(
        'group-1',
        afterId: 0,
        minAgeHours: 48,
      );
      expect(memories, hasLength(1));
      expect(memories.first.sourceType, equals(MemorySourceType.message));
    });

    test('returns results ordered by id ascending', () {
      for (var i = 0; i < 5; i++) {
        queries.insertMemoryEmbedding(
          chatId: 'group-1',
          sourceType: MemorySourceType.message,
          sourceText: 'Message $i',
        );
      }
      database.handle.execute(
        "UPDATE memory_embeddings SET created_at = datetime('now', '-72 hours')",
      );

      final memories = queries.getUnconsolidatedMemories(
        'group-1',
        afterId: 0,
        minAgeHours: 48,
      );
      for (var i = 0; i < memories.length - 1; i++) {
        expect(memories[i].id, lessThan(memories[i + 1].id));
      }
    });
  });

  group('insertMemorySummary', () {
    test('inserts and returns ID', () {
      final id = queries.insertMemorySummary(
        chatId: 'group-1',
        summaryText: 'A concise summary of conversations.',
        messageIdFrom: 1,
        messageIdTo: 20,
        messageCount: 20,
      );

      expect(id, greaterThan(0));

      final rows = database.handle.select(
        'SELECT * FROM memory_summaries WHERE id = ?',
        [id],
      );
      expect(rows, hasLength(1));
      expect(rows.first['chat_id'], equals('group-1'));
      expect(rows.first['summary_text'],
          equals('A concise summary of conversations.'));
      expect(rows.first['message_id_from'], equals(1));
      expect(rows.first['message_id_to'], equals(20));
      expect(rows.first['message_count'], equals(20));
    });
  });

  group('deleteMemoryEmbeddings', () {
    test('deletes specified IDs and preserves others', () {
      final id1 = queries.insertMemoryEmbedding(
        chatId: 'group-1',
        sourceType: MemorySourceType.message,
        sourceText: 'Keep this',
      );
      final id2 = queries.insertMemoryEmbedding(
        chatId: 'group-1',
        sourceType: MemorySourceType.message,
        sourceText: 'Delete this',
      );
      final id3 = queries.insertMemoryEmbedding(
        chatId: 'group-1',
        sourceType: MemorySourceType.message,
        sourceText: 'Delete this too',
      );

      queries.deleteMemoryEmbeddings([id2, id3]);

      expect(queries.countMemoryEmbeddings(), equals(1));

      final remaining = database.handle.select(
        'SELECT id FROM memory_embeddings',
      );
      expect(remaining.first['id'], equals(id1));
    });

    test('handles empty list gracefully', () {
      queries.insertMemoryEmbedding(
        chatId: 'group-1',
        sourceType: MemorySourceType.message,
        sourceText: 'Should remain',
      );

      queries.deleteMemoryEmbeddings([]);
      expect(queries.countMemoryEmbeddings(), equals(1));
    });
  });

  group('runInTransaction', () {
    test('commits on success', () {
      queries.runInTransaction(() {
        queries.insertMemoryEmbedding(
          chatId: 'group-1',
          sourceType: MemorySourceType.message,
          sourceText: 'Inside transaction',
        );
      });

      expect(queries.countMemoryEmbeddings(), equals(1));
    });

    test('rolls back on error', () {
      try {
        queries.runInTransaction(() {
          queries.insertMemoryEmbedding(
            chatId: 'group-1',
            sourceType: MemorySourceType.message,
            sourceText: 'Should be rolled back',
          );
          throw Exception('Deliberate failure');
        });
      } on Exception {
        // Expected.
      }

      expect(queries.countMemoryEmbeddings(), equals(0));
    });
  });

  group('getEmbeddedMessageIds', () {
    test('returns set of message IDs with embeddings', () {
      queries.insertMemoryEmbedding(
        messageId: 100,
        chatId: 'group-1',
        sourceType: MemorySourceType.message,
        sourceText: 'Text 1',
        embedding: List.filled(512, 0.1),
      );
      queries.insertMemoryEmbedding(
        messageId: 200,
        chatId: 'group-1',
        sourceType: MemorySourceType.message,
        sourceText: 'Text 2',
      );

      final ids = queries.getEmbeddedMessageIds('group-1');
      expect(ids, contains(100));
      expect(ids, contains(200));
    });
  });
}
