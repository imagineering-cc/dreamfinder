import 'package:dreamfinder/src/db/database.dart';
import 'package:dreamfinder/src/db/queries.dart';
import 'package:dreamfinder/src/memory/embedding_backfill.dart';
import 'package:dreamfinder/src/memory/embedding_client.dart';
import 'package:dreamfinder/src/memory/memory_record.dart';
import 'package:test/test.dart';

/// Fake [EmbeddingClient] that returns deterministic embeddings.
class FakeBackfillClient implements EmbeddingClient {
  int callCount = 0;
  bool shouldThrow = false;

  /// Indices (0-based within the backfill run) that should throw.
  final Set<int> failIndices = {};

  @override
  int get dimensions => 3;

  @override
  Future<List<List<double>>> embed(
    List<String> texts, {
    String inputType = 'document',
  }) async {
    if (shouldThrow) throw const EmbeddingException('network error');
    final result = <List<double>>[];
    for (final _ in texts) {
      if (failIndices.contains(callCount)) {
        callCount++;
        throw const EmbeddingException('transient failure');
      }
      result.add([0.1, 0.2, 0.3]);
      callCount++;
    }
    return result;
  }
}

void main() {
  late BotDatabase database;
  late Queries queries;
  late FakeBackfillClient client;

  setUp(() {
    database = BotDatabase.inMemory();
    queries = Queries(database);
    client = FakeBackfillClient();
  });

  tearDown(() {
    database.close();
  });

  group('EmbeddingBackfill', () {
    test('embeds records with null embeddings and returns success count',
        () async {
      // Insert two records without embeddings.
      queries.insertMemoryEmbedding(
        chatId: 'group-1',
        sourceType: MemorySourceType.message,
        sourceText: 'Unembedded message 1',
      );
      queries.insertMemoryEmbedding(
        chatId: 'group-1',
        sourceType: MemorySourceType.message,
        sourceText: 'Unembedded message 2',
      );

      final backfill = EmbeddingBackfill(
        queries: queries,
        client: client,
      );

      final count = await backfill.backfill();

      expect(count, equals(2));

      // Verify embeddings were stored.
      final unembedded = queries.getUnembeddedRecords();
      expect(unembedded, isEmpty);
    });

    test('returns 0 when no unembedded records exist', () async {
      queries.insertMemoryEmbedding(
        chatId: 'group-1',
        sourceType: MemorySourceType.message,
        sourceText: 'Already embedded',
        embedding: [0.1, 0.2, 0.3],
      );

      final backfill = EmbeddingBackfill(
        queries: queries,
        client: client,
      );

      final count = await backfill.backfill();
      expect(count, equals(0));
      expect(client.callCount, equals(0));
    });

    test('handles per-record embedding failure gracefully', () async {
      queries.insertMemoryEmbedding(
        chatId: 'group-1',
        sourceType: MemorySourceType.message,
        sourceText: 'Will fail',
      );
      queries.insertMemoryEmbedding(
        chatId: 'group-1',
        sourceType: MemorySourceType.message,
        sourceText: 'Will succeed',
      );

      // First embed call fails, second succeeds.
      client.failIndices.add(0);

      final backfill = EmbeddingBackfill(
        queries: queries,
        client: client,
      );

      final count = await backfill.backfill();

      // Only the second record should have been embedded.
      expect(count, equals(1));

      // One record should still be unembedded.
      final remaining = queries.getUnembeddedRecords();
      expect(remaining, hasLength(1));
      expect(remaining.first.sourceText, equals('Will fail'));
    });

    test('respects batchLimit', () async {
      for (var i = 0; i < 10; i++) {
        queries.insertMemoryEmbedding(
          chatId: 'group-1',
          sourceType: MemorySourceType.message,
          sourceText: 'Record $i',
        );
      }

      final backfill = EmbeddingBackfill(
        queries: queries,
        client: client,
        batchLimit: 3,
      );

      final count = await backfill.backfill();
      expect(count, equals(3));

      // 7 records should remain unembedded.
      final remaining = queries.getUnembeddedRecords();
      expect(remaining, hasLength(7));
    });

    test('concurrent run guard prevents double execution', () async {
      for (var i = 0; i < 5; i++) {
        queries.insertMemoryEmbedding(
          chatId: 'group-1',
          sourceType: MemorySourceType.message,
          sourceText: 'Record $i',
        );
      }

      final backfill = EmbeddingBackfill(
        queries: queries,
        client: client,
      );

      // Start two backfills concurrently.
      final results = await Future.wait([
        backfill.backfill(),
        backfill.backfill(),
      ]);

      // One should run (5), the other should return 0 (guard).
      final total = results.reduce((a, b) => a + b);
      expect(total, equals(5));
      expect(results, contains(0));
    });

    test('processes both message and summary types', () async {
      queries.insertMemoryEmbedding(
        chatId: 'group-1',
        sourceType: MemorySourceType.message,
        sourceText: 'Unembedded message',
      );
      queries.insertMemoryEmbedding(
        chatId: 'group-1',
        sourceType: MemorySourceType.summary,
        sourceText: 'Unembedded summary',
      );

      final backfill = EmbeddingBackfill(
        queries: queries,
        client: client,
      );

      final count = await backfill.backfill();
      expect(count, equals(2));

      final remaining = queries.getUnembeddedRecords();
      expect(remaining, isEmpty);
    });
  });
}
