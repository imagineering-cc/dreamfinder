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
