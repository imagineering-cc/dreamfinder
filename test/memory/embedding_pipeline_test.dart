import 'package:dreamfinder/src/db/database.dart';
import 'package:dreamfinder/src/db/queries/memory_queries.dart';
import 'package:dreamfinder/src/memory/embedding_client.dart';
import 'package:dreamfinder/src/memory/embedding_pipeline.dart';
import 'package:dreamfinder/src/memory/memory_record.dart';
import 'package:test/test.dart';

/// In-memory embedding client that returns deterministic vectors.
class FakeEmbeddingClient implements EmbeddingClient {
  int callCount = 0;
  bool shouldThrow = false;

  @override
  int get dimensions => 512;

  @override
  Future<List<List<double>>> embed(
    List<String> texts, {
    String inputType = 'document',
  }) async {
    callCount++;
    if (shouldThrow) {
      throw const EmbeddingException('fake error');
    }
    return [
      for (var i = 0; i < texts.length; i++)
        List.filled(512, (i + 1) * 0.1),
    ];
  }
}

/// Minimal query accessor backed by a real in-memory SQLite database.
class TestQueryAccessor with MemoryQueries implements MemoryQueryAccessor {
  TestQueryAccessor(this.db);

  @override
  final BotDatabase db;
}

void main() {
  late BotDatabase database;
  late TestQueryAccessor queries;
  late FakeEmbeddingClient fakeClient;
  late EmbeddingPipeline pipeline;

  setUp(() {
    database = BotDatabase.inMemory();
    queries = TestQueryAccessor(database);
    fakeClient = FakeEmbeddingClient();
    pipeline = EmbeddingPipeline(client: fakeClient, queries: queries);
  });

  tearDown(() {
    database.close();
  });

  test('queues and embeds a user+assistant turn', () async {
    pipeline.queue(
      chatId: 'group-1',
      userText: 'What is the Dawn Gate?',
      assistantText: 'The Dawn Gate is an emoji gateway I created.',
      senderName: 'Nick',
    );

    // Wait for the async embedding to complete.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(fakeClient.callCount, equals(1));

    final records = queries.getEmbeddedMemories(chatId: 'group-1');
    expect(records, hasLength(1));
    expect(records.first.sourceText, contains('Nick: What is the Dawn Gate?'));
    expect(records.first.sourceText, contains('Dreamfinder:'));
    expect(records.first.embedding, isNotNull);
    expect(records.first.embedding!.length, equals(512));
    expect(records.first.visibility, equals(MemoryVisibility.sameChat));
  });

  test('skips short messages', () async {
    pipeline.queue(
      chatId: 'group-1',
      userText: 'ok',
      assistantText: 'got it',
    );

    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(fakeClient.callCount, equals(0));
    expect(queries.countMemoryEmbeddings(), equals(0));
  });

  test('stores source text even when embedding fails', () async {
    fakeClient.shouldThrow = true;

    pipeline.queue(
      chatId: 'group-1',
      userText: 'Tell me about the project structure.',
      assistantText: 'The project is organized into several layers...',
    );

    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(fakeClient.callCount, equals(1));

    // Source text should be stored, but embedding should be null.
    final count = queries.countMemoryEmbeddings();
    expect(count, equals(1));

    final records = queries.getEmbeddedMemories(chatId: 'group-1');
    // getEmbeddedMemories filters for non-null embeddings.
    expect(records, isEmpty);
  });

  test('respects custom visibility', () async {
    pipeline.queue(
      chatId: 'dm-admin',
      userText: 'Remember this for all chats.',
      assistantText: 'I will remember this.',
      visibility: MemoryVisibility.crossChat,
    );

    await Future<void>.delayed(const Duration(milliseconds: 50));

    final records = queries.getEmbeddedMemories();
    expect(records.first.visibility, equals(MemoryVisibility.crossChat));
  });

  test('embeds long user text even with short assistant reply', () async {
    pipeline.queue(
      chatId: 'group-1',
      userText: 'Here is a detailed description of the architecture...',
      assistantText: 'Noted!',
    );

    await Future<void>.delayed(const Duration(milliseconds: 50));

    // User text is long enough, so it should be embedded.
    expect(fakeClient.callCount, equals(1));
    expect(queries.countMemoryEmbeddings(), equals(1));
  });

  test('uses custom bot name in source text', () async {
    final customPipeline = EmbeddingPipeline(
      client: fakeClient,
      queries: queries,
      getBotName: () => 'Gizmo',
    );

    customPipeline.queue(
      chatId: 'group-1',
      userText: 'What is the Dawn Gate?',
      assistantText: 'The Dawn Gate is an emoji gateway.',
      senderName: 'Nick',
    );

    await Future<void>.delayed(const Duration(milliseconds: 50));

    final records = queries.getEmbeddedMemories(chatId: 'group-1');
    expect(records, hasLength(1));
    expect(records.first.sourceText, contains('Gizmo:'));
    expect(records.first.sourceText, isNot(contains('Dreamfinder:')));
  });

  test('defaults bot name to Dreamfinder', () async {
    pipeline.queue(
      chatId: 'group-1',
      userText: 'What is the Dawn Gate?',
      assistantText: 'The Dawn Gate is an emoji gateway.',
      senderName: 'Nick',
    );

    await Future<void>.delayed(const Duration(milliseconds: 50));

    final records = queries.getEmbeddedMemories(chatId: 'group-1');
    expect(records, hasLength(1));
    expect(records.first.sourceText, contains('Dreamfinder:'));
  });

  test('reflects bot name changes at runtime', () async {
    var currentName = 'Dreamfinder';
    final reactivePipeline = EmbeddingPipeline(
      client: fakeClient,
      queries: queries,
      getBotName: () => currentName,
    );

    reactivePipeline.queue(
      chatId: 'group-1',
      userText: 'Hello there!',
      assistantText: 'Hi! Nice to meet you.',
      senderName: 'Nick',
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // Change the name at runtime (simulates set_bot_identity).
    currentName = 'Figment';

    reactivePipeline.queue(
      chatId: 'group-1',
      userText: 'What is your name?',
      assistantText: 'I am Figment!',
      senderName: 'Nick',
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final records = queries.getEmbeddedMemories(chatId: 'group-1');
    expect(records, hasLength(2));
    final sourceTexts = records.map((r) => r.sourceText).toList();
    expect(sourceTexts, contains(contains('Figment:')));
    expect(sourceTexts, contains(contains('Dreamfinder:')));
  });
}
