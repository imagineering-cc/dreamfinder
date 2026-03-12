import 'package:dreamfinder/src/db/database.dart';
import 'package:dreamfinder/src/db/queries.dart';
import 'package:dreamfinder/src/memory/embedding_client.dart';
import 'package:dreamfinder/src/memory/memory_consolidator.dart';
import 'package:dreamfinder/src/memory/memory_record.dart';
import 'package:dreamfinder/src/memory/summarization_client.dart';
import 'package:test/test.dart';

/// Fake embedding client that returns deterministic vectors.
class FakeEmbeddingClient implements EmbeddingClient {
  int callCount = 0;
  bool shouldFail = false;

  @override
  int get dimensions => 512;

  @override
  Future<List<List<double>>> embed(
    List<String> texts, {
    String inputType = 'document',
  }) async {
    callCount++;
    if (shouldFail) throw const EmbeddingException('Fake embedding failure');
    return [for (final _ in texts) List.filled(512, 0.42)];
  }
}

void main() {
  late BotDatabase database;
  late Queries queries;
  late FakeEmbeddingClient embeddingClient;
  late List<String> summarizedTexts;

  setUp(() {
    database = BotDatabase.inMemory();
    queries = Queries(database);
    embeddingClient = FakeEmbeddingClient();
    summarizedTexts = [];
  });

  tearDown(() {
    database.close();
  });

  /// Creates a consolidator with a fake summarizer that captures inputs.
  MemoryConsolidator createConsolidator({
    int batchSize = 20,
    int minAgeHours = 48,
    String summaryResponse = 'Consolidated summary of conversation.',
    bool summarizerShouldFail = false,
  }) {
    final summarizer = SummarizationClient(
      createSummarization: (prompt) async {
        if (summarizerShouldFail) {
          throw Exception('Summarization API failure');
        }
        summarizedTexts.add(prompt);
        return summaryResponse;
      },
    );
    return MemoryConsolidator(
      queries: queries,
      summarizer: summarizer,
      embeddingClient: embeddingClient,
      batchSize: batchSize,
      minAgeHours: minAgeHours,
    );
  }

  /// Inserts N old message-type embeddings for a chat, backdated by [hoursAgo].
  List<int> insertOldMemories(
    String chatId,
    int count, {
    int hoursAgo = 72,
    MemoryVisibility visibility = MemoryVisibility.sameChat,
  }) {
    final ids = <int>[];
    for (var i = 0; i < count; i++) {
      final id = queries.insertMemoryEmbedding(
        chatId: chatId,
        sourceType: MemorySourceType.message,
        sourceText: 'Conversation turn $i in $chatId',
        visibility: visibility,
        embedding: List.filled(512, 0.1),
      );
      ids.add(id);
    }
    // Backdate all inserted records.
    database.handle.execute(
      "UPDATE memory_embeddings SET created_at = datetime('now', '-$hoursAgo hours') "
      "WHERE chat_id = ? AND source_type = 'message'",
      [chatId],
    );
    return ids;
  }

  group('MemoryConsolidator', () {
    test('skips memories younger than minAgeHours', () async {
      // Insert 25 recent memories (not backdated).
      for (var i = 0; i < 25; i++) {
        queries.insertMemoryEmbedding(
          chatId: 'group-1',
          sourceType: MemorySourceType.message,
          sourceText: 'Recent message $i',
          embedding: List.filled(512, 0.1),
        );
      }

      final consolidator = createConsolidator();
      await consolidator.consolidate();

      // No summaries created — all memories are too recent.
      expect(summarizedTexts, isEmpty);
      expect(queries.countMemoryEmbeddings(), equals(25));
    });

    test('consolidates batch of 20+ old memories into summary', () async {
      insertOldMemories('group-1', 25);

      final consolidator = createConsolidator();
      await consolidator.consolidate();

      // 20 originals deleted, 1 summary created + 5 remaining = 6 total.
      expect(queries.countMemoryEmbeddings(), equals(6));
      expect(summarizedTexts, hasLength(1));

      // Verify summary was inserted into memory_summaries table.
      final summaries = database.handle.select(
        'SELECT * FROM memory_summaries WHERE chat_id = ?',
        ['group-1'],
      );
      expect(summaries, hasLength(1));
      expect(summaries.first['message_count'], equals(20));
      expect(summaries.first['summary_text'],
          equals('Consolidated summary of conversation.'));
    });

    test('groups by visibility, creates separate summaries per level',
        () async {
      insertOldMemories('group-1', 22,
          visibility: MemoryVisibility.sameChat);
      insertOldMemories('group-1', 22,
          visibility: MemoryVisibility.crossChat);

      final consolidator = createConsolidator();
      await consolidator.consolidate();

      // Each visibility group should have its own summary.
      expect(summarizedTexts, hasLength(2));

      final summaries = database.handle.select(
        'SELECT * FROM memory_summaries WHERE chat_id = ?',
        ['group-1'],
      );
      expect(summaries, hasLength(2));
    });

    test('idempotent on re-run (watermark prevents reprocessing)', () async {
      insertOldMemories('group-1', 25);

      final consolidator = createConsolidator();
      await consolidator.consolidate();

      final countAfterFirst = queries.countMemoryEmbeddings();
      final summariesAfterFirst = summarizedTexts.length;

      // Second run — should be a no-op.
      await consolidator.consolidate();

      expect(queries.countMemoryEmbeddings(), equals(countAfterFirst));
      expect(summarizedTexts, hasLength(summariesAfterFirst));
    });

    test('handles summarization failure gracefully', () async {
      insertOldMemories('group-1', 25);

      final consolidator = createConsolidator(summarizerShouldFail: true);
      await consolidator.consolidate();

      // No records should be deleted when summarization fails.
      expect(queries.countMemoryEmbeddings(), equals(25));
      // Watermark should not advance.
      expect(queries.getLastConsolidatedId('group-1'), equals(0));
    });

    test('handles embedding failure gracefully', () async {
      insertOldMemories('group-1', 25);
      embeddingClient.shouldFail = true;

      final consolidator = createConsolidator();
      await consolidator.consolidate();

      // Summary should still be stored, but embedding remains null.
      // 20 originals deleted + 1 summary (no embedding) + 5 remaining = 6.
      expect(queries.countMemoryEmbeddings(), equals(6));

      // The summary embedding record should exist but without an embedding.
      final summaryRecords = queries.getEmbeddedMemories(chatId: 'group-1');
      // getEmbeddedMemories filters for non-null embeddings, so the summary
      // without an embedding won't appear. The 5 remaining originals have
      // embeddings.
      expect(summaryRecords, hasLength(5));
    });

    test('skips chats with fewer than batchSize candidates', () async {
      insertOldMemories('group-1', 15); // < 20

      final consolidator = createConsolidator();
      await consolidator.consolidate();

      expect(summarizedTexts, isEmpty);
      expect(queries.countMemoryEmbeddings(), equals(15));
    });

    test('concurrent run guard prevents double execution', () async {
      insertOldMemories('group-1', 25);

      // Use a slow summarizer to simulate long-running consolidation.
      final summarizer = SummarizationClient(
        createSummarization: (prompt) async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return 'Summary';
        },
      );
      final consolidator = MemoryConsolidator(
        queries: queries,
        summarizer: summarizer,
        embeddingClient: embeddingClient,
      );

      // Launch two concurrent runs.
      final results = await Future.wait([
        consolidator.consolidate(),
        consolidator.consolidate(),
      ]);

      // Only one should have actually run — 20 deleted + 1 summary + 5 = 6.
      // If both ran, we'd see incorrect counts.
      expect(results, hasLength(2));
      expect(queries.countMemoryEmbeddings(), equals(6));
    });

    test('processes multiple chats independently', () async {
      insertOldMemories('group-1', 25);
      insertOldMemories('group-2', 25);

      final consolidator = createConsolidator();
      await consolidator.consolidate();

      expect(summarizedTexts, hasLength(2));

      // Each chat: 25 - 20 + 1 summary = 6.
      expect(queries.countMemoryEmbeddings(), equals(12));
    });

    test('one failing chat does not block others', () async {
      insertOldMemories('group-1', 25);
      insertOldMemories('group-2', 25);

      // Summarizer fails only for group-1.
      var callCount = 0;
      final summarizer = SummarizationClient(
        createSummarization: (prompt) async {
          callCount++;
          if (callCount == 1) {
            throw Exception('Fail for first chat');
          }
          return 'Summary';
        },
      );
      final consolidator = MemoryConsolidator(
        queries: queries,
        summarizer: summarizer,
        embeddingClient: embeddingClient,
      );

      await consolidator.consolidate();

      // group-1 failed: 25 remain. group-2 succeeded: 6 remain.
      expect(queries.countMemoryEmbeddings(), equals(31));
    });
  });
}
