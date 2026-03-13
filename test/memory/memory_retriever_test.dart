import 'package:dreamfinder/src/memory/embedding_client.dart';
import 'package:dreamfinder/src/memory/memory_record.dart';
import 'package:dreamfinder/src/memory/memory_retriever.dart';
import 'package:test/test.dart';

/// Deterministic embedding client that maps specific texts to known vectors.
class FakeRetrievalClient implements EmbeddingClient {
  bool shouldThrow = false;

  @override
  int get dimensions => 3;

  @override
  Future<List<List<double>>> embed(
    List<String> texts, {
    String inputType = 'document',
  }) async {
    if (shouldThrow) throw const EmbeddingException('network error');
    // Return a simple deterministic vector for each text.
    return [
      for (final text in texts) _vectorForText(text),
    ];
  }

  /// Generates a deterministic unit vector based on text content.
  List<double> _vectorForText(String text) {
    if (text.contains('Dawn Gate')) return [1.0, 0.0, 0.0];
    if (text.contains('calendar')) return [0.0, 1.0, 0.0];
    if (text.contains('standup')) return [0.0, 0.0, 1.0];
    // Generic: spread across all dimensions.
    return [0.577, 0.577, 0.577];
  }
}

void main() {
  late FakeRetrievalClient fakeClient;

  setUp(() {
    fakeClient = FakeRetrievalClient();
  });

  List<MemoryRecord> makeRecords({
    String chatId = 'group-1',
    MemoryVisibility visibility = MemoryVisibility.sameChat,
  }) {
    return [
      MemoryRecord(
        id: 1,
        chatId: chatId,
        sourceType: MemorySourceType.message,
        sourceText: 'Nick asked about the Dawn Gate. Dreamfinder described it.',
        visibility: visibility,
        embedding: [1.0, 0.0, 0.0], // Dawn Gate vector
        createdAt: '2026-03-01T12:00:00',
      ),
      MemoryRecord(
        id: 2,
        chatId: chatId,
        sourceType: MemorySourceType.message,
        sourceText: 'Discussion about calendar integration.',
        visibility: visibility,
        embedding: [0.0, 1.0, 0.0], // Calendar vector
        createdAt: '2026-03-02T12:00:00',
      ),
      MemoryRecord(
        id: 3,
        chatId: chatId,
        sourceType: MemorySourceType.message,
        sourceText: 'Standup configuration for the team.',
        visibility: visibility,
        embedding: [0.0, 0.0, 1.0], // Standup vector
        createdAt: '2026-03-03T12:00:00',
      ),
    ];
  }

  test('retrieves most similar memory for a query', () async {
    final retriever = MemoryRetriever(
      client: fakeClient,
      loadMemories: (_) => makeRecords(),
    );

    final results = await retriever.retrieve('Tell me about the Dawn Gate', 'group-1');

    expect(results, isNotEmpty);
    expect(results.first.record.id, equals(1));
    expect(results.first.score, closeTo(1.0, 0.01));
  });

  test('returns results sorted by descending similarity', () async {
    final retriever = MemoryRetriever(
      client: fakeClient,
      loadMemories: (_) => makeRecords(),
    );

    final results = await retriever.retrieve('Dawn Gate', 'group-1');

    for (var i = 0; i < results.length - 1; i++) {
      expect(results[i].score, greaterThanOrEqualTo(results[i + 1].score));
    }
  });

  test('filters out results below minimum score', () async {
    final retriever = MemoryRetriever(
      client: fakeClient,
      loadMemories: (_) => makeRecords(),
      minScore: 0.9,
    );

    final results = await retriever.retrieve('Dawn Gate', 'group-1');

    // Only the Dawn Gate memory should match at 0.9+ similarity.
    expect(results, hasLength(1));
    expect(results.first.record.id, equals(1));
  });

  test('respects topK limit', () async {
    final retriever = MemoryRetriever(
      client: fakeClient,
      loadMemories: (_) => makeRecords(),
      topK: 1,
      minScore: 0.0,
    );

    final results = await retriever.retrieve('Dawn Gate', 'group-1');
    expect(results, hasLength(1));
  });

  test('returns empty list when no memories exist', () async {
    final retriever = MemoryRetriever(
      client: fakeClient,
      loadMemories: (_) => [],
    );

    final results = await retriever.retrieve('anything', 'group-1');
    expect(results, isEmpty);
  });

  test('returns empty list when embedding fails (graceful degradation)', () async {
    fakeClient.shouldThrow = true;

    final retriever = MemoryRetriever(
      client: fakeClient,
      loadMemories: (_) => makeRecords(),
    );

    final results = await retriever.retrieve('Dawn Gate', 'group-1');
    expect(results, isEmpty);
  });

  test('skips records with null embeddings', () async {
    final records = [
      MemoryRecord(
        id: 1,
        chatId: 'group-1',
        sourceType: MemorySourceType.message,
        sourceText: 'Has embedding',
        visibility: MemoryVisibility.sameChat,
        embedding: [1.0, 0.0, 0.0],
        createdAt: '2026-03-01T12:00:00',
      ),
      const MemoryRecord(
        id: 2,
        chatId: 'group-1',
        sourceType: MemorySourceType.message,
        sourceText: 'No embedding yet',
        visibility: MemoryVisibility.sameChat,
        createdAt: '2026-03-02T12:00:00',
      ),
    ];

    final retriever = MemoryRetriever(
      client: fakeClient,
      loadMemories: (_) => records,
      minScore: 0.0,
    );

    final results = await retriever.retrieve('Dawn Gate', 'group-1');
    // Only the record with an embedding should be scored.
    expect(results.every((r) => r.record.embedding != null), isTrue);
  });

  test('skipRecentMinutes filters out recent memories', () async {
    final now = DateTime.now();
    final recentTime = now.subtract(const Duration(minutes: 10)).toIso8601String();
    final oldTime = now.subtract(const Duration(hours: 2)).toIso8601String();

    final records = [
      MemoryRecord(
        id: 1,
        chatId: 'group-1',
        sourceType: MemorySourceType.message,
        sourceText: 'Recent Dawn Gate discussion',
        visibility: MemoryVisibility.sameChat,
        embedding: [1.0, 0.0, 0.0],
        createdAt: recentTime, // 10 minutes ago — in sliding window
      ),
      MemoryRecord(
        id: 2,
        chatId: 'group-1',
        sourceType: MemorySourceType.message,
        sourceText: 'Old Dawn Gate lore from last week',
        visibility: MemoryVisibility.sameChat,
        embedding: [0.95, 0.05, 0.0],
        createdAt: oldTime, // 2 hours ago — not in window
      ),
    ];

    final retriever = MemoryRetriever(
      client: fakeClient,
      loadMemories: (_) => records,
      minScore: 0.0,
    );

    // With skipRecentMinutes=60, the 10-min-old record should be excluded.
    final results = await retriever.retrieve(
      'Dawn Gate',
      'group-1',
      skipRecentMinutes: 60,
    );

    expect(results, hasLength(1));
    expect(results.first.record.id, equals(2));
  });

  test('skipRecentMinutes defaults to null (no filtering)', () async {
    final now = DateTime.now();
    final recentTime = now.subtract(const Duration(minutes: 5)).toIso8601String();

    final records = [
      MemoryRecord(
        id: 1,
        chatId: 'group-1',
        sourceType: MemorySourceType.message,
        sourceText: 'Very recent Dawn Gate chat',
        visibility: MemoryVisibility.sameChat,
        embedding: [1.0, 0.0, 0.0],
        createdAt: recentTime,
      ),
    ];

    final retriever = MemoryRetriever(
      client: fakeClient,
      loadMemories: (_) => records,
      minScore: 0.0,
    );

    // Without skipRecentMinutes, recent records should be included.
    final results = await retriever.retrieve('Dawn Gate', 'group-1');
    expect(results, hasLength(1));
  });

  test('topK override returns more than default', () async {
    final retriever = MemoryRetriever(
      client: fakeClient,
      loadMemories: (_) => makeRecords(),
      topK: 1,
      minScore: 0.0,
    );

    // Default topK is 1, but override with 3.
    final results = await retriever.retrieve('Dawn Gate', 'group-1', topK: 3);
    expect(results, hasLength(3));

    // Without override, should respect constructor topK.
    final defaultResults = await retriever.retrieve('Dawn Gate', 'group-1');
    expect(defaultResults, hasLength(1));
  });

  test('same-chat memory is retrieved; cross-chat memory from other group is not', () async {
    final groupARecords = [
      MemoryRecord(
        id: 1,
        chatId: 'group-A',
        sourceType: MemorySourceType.message,
        sourceText: 'Dawn Gate discussion in group A',
        visibility: MemoryVisibility.sameChat,
        embedding: [1.0, 0.0, 0.0],
        createdAt: '2026-03-01T12:00:00',
      ),
      MemoryRecord(
        id: 2,
        chatId: 'group-B',
        sourceType: MemorySourceType.message,
        sourceText: 'Dawn Gate mention in group B',
        visibility: MemoryVisibility.sameChat,
        embedding: [1.0, 0.0, 0.0],
        createdAt: '2026-03-02T12:00:00',
      ),
      MemoryRecord(
        id: 3,
        chatId: 'group-B',
        sourceType: MemorySourceType.message,
        sourceText: 'Shared knowledge from group B',
        visibility: MemoryVisibility.crossChat,
        embedding: [0.9, 0.1, 0.0],
        createdAt: '2026-03-03T12:00:00',
      ),
    ];

    // Simulate getVisibleMemories — only same-chat or cross-chat visible.
    List<MemoryRecord> loadVisible(String chatId) {
      return groupARecords
          .where((r) =>
              r.visibility == MemoryVisibility.crossChat ||
              r.chatId == chatId)
          .toList();
    }

    final retriever = MemoryRetriever(
      client: fakeClient,
      loadMemories: loadVisible,
      minScore: 0.0,
    );

    final results = await retriever.retrieve('Dawn Gate', 'group-A');

    // Should include group-A same_chat record and group-B cross_chat record.
    // Should NOT include group-B same_chat record.
    final ids = results.map((r) => r.record.id).toSet();
    expect(ids, contains(1)); // group-A same_chat
    expect(ids, isNot(contains(2))); // group-B same_chat — filtered out
    expect(ids, contains(3)); // group-B cross_chat — visible everywhere
  });
}
