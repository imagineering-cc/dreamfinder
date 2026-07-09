import 'package:dreamfinder/src/db/database.dart';
import 'package:dreamfinder/src/db/queries.dart';
import 'package:dreamfinder/src/immune/golden_seeder.dart';
import 'package:dreamfinder/src/immune/golden_sentinels.dart';
import 'package:dreamfinder/src/immune/probe.dart';
import 'package:dreamfinder/src/immune/probes/content_integrity_probe.dart';
import 'package:dreamfinder/src/immune/sentinel.dart';
import 'package:dreamfinder/src/memory/embedding_client.dart';
import 'package:dreamfinder/src/memory/memory_retriever.dart';
import 'package:test/test.dart';

/// Deterministic embedding client: every text embeds to the SAME vector, so
/// cosine similarity is 1.0 for any query — retrieval of the seeded golden is
/// deterministic (the probe must never flap on its own seed).
class _ConstantClient implements EmbeddingClient {
  int callCount = 0;
  @override
  int get dimensions => 3;
  @override
  Future<List<List<double>>> embed(List<String> texts,
      {String inputType = 'document'}) async {
    callCount += texts.length;
    return [
      for (final _ in texts) const [0.1, 0.2, 0.3]
    ];
  }
}

void main() {
  late BotDatabase database;
  late Queries queries;
  late _ConstantClient client;
  final sealer = SentinelSealer('test-immune-key');
  const golden = Sentinel(
    id: 'immune_content_golden',
    payload: 'the golem remembers what the corpus must return',
    version: 'v1',
  );

  setUp(() {
    database = BotDatabase.inMemory();
    queries = Queries(database);
    client = _ConstantClient();
  });
  tearDown(() => database.close());

  GoldenSeeder seeder() =>
      GoldenSeeder(client: client, queries: queries, sealer: sealer);

  group('GoldenSeeder', () {
    test('seeded golden is isolated to the immune chatId', () async {
      await seeder().seed(const [golden]);

      // Invisible to any real conversation.
      expect(queries.getVisibleMemories('some-real-chat'), isEmpty);
      // Visible only when scoped to the reserved immune chatId.
      final immune = queries.getVisibleMemories(immuneGoldenChatId);
      expect(immune, hasLength(1));
      final parsed = parseSealedGolden(immune.single.sourceText);
      expect(parsed?.id, golden.id);
    });

    test('is idempotent: a second run seeds nothing and makes no embed call',
        () async {
      final first = await seeder().seed(const [golden]);
      expect(first, [golden.id]);
      expect(client.callCount, 1);

      final second = await seeder().seed(const [golden]);
      expect(second, isEmpty);
      expect(client.callCount, 1,
          reason: 'no re-embed on an already-seeded run');
      expect(queries.getVisibleMemories(immuneGoldenChatId), hasLength(1));
    });

    test('round-trips through the real retriever into a passing probe',
        () async {
      await seeder().seed(const [golden]);

      final retriever = MemoryRetriever(
        client: client,
        loadMemories: queries.getVisibleMemories,
      );
      final fetch = buildGoldenFetcher(
        retriever: retriever,
        goldens: const [golden],
      );

      // The fetcher recovers the exact sealed golden via the real path.
      final got = await fetch(golden.id);
      expect(got, isNotNull);
      expect(got!.payload, golden.payload);
      expect(sealer.verify(golden, got.seal), isTrue);

      // And that fetcher drives a ContentIntegrityProbe to `ok`.
      final store = FixtureSentinelStore.sealed(sealer, const [golden]);
      final probe = ContentIntegrityProbe(
        id: 'probe_content_integrity',
        sentinelId: golden.id,
        store: store,
        sealer: sealer,
        fetchSealed: fetch,
      );
      final r = await probe.run();
      expect(r.status, ProbeStatus.ok);
    });

    test('fetcher returns null for an unknown sentinel id', () async {
      await seeder().seed(const [golden]);
      final retriever = MemoryRetriever(
        client: client,
        loadMemories: queries.getVisibleMemories,
      );
      final fetch =
          buildGoldenFetcher(retriever: retriever, goldens: const [golden]);
      expect(await fetch('no-such-id'), isNull);
    });
  });

  group('parseSealedGolden', () {
    test('returns null on malformed / foreign rows (tolerant)', () {
      expect(parseSealedGolden('not json'), isNull);
      expect(parseSealedGolden('{"id":"x"}'), isNull); // missing payload/seal
      expect(parseSealedGolden('[1,2,3]'), isNull); // not an object
    });
  });
}
