/// Seeds golden sentinels into the RAG corpus and builds the fetcher that
/// retrieves them back through the real memory path.
///
/// This is boot/setup INFRA, not a probe: it WRITES (seeds the golden row), so it
/// deliberately lives outside the detect-only [ProbeRegistry] admission control
/// (which rejects write/send *probes*). The probe that runs every tick stays
/// pure-read — it only calls the fetcher this module builds.
library;

import 'dart:convert';

import '../db/queries.dart';
import '../memory/embedding_client.dart';
import '../memory/memory_record.dart';
import '../memory/memory_retriever.dart';
import 'golden_sentinels.dart';
import 'probes/content_integrity_probe.dart';
import 'sentinel.dart';

/// A parsed `(id, payload, seal)` triple from a seeded golden row's source_text.
typedef ParsedGolden = ({String id, String payload, String seal});

/// Parses a seeded golden's `source_text` JSON, or null if it is not a
/// well-formed golden record. Tolerant by design: a malformed/foreign row under
/// the immune chatId is simply skipped, never thrown on.
ParsedGolden? parseSealedGolden(String sourceText) {
  try {
    final decoded = jsonDecode(sourceText);
    if (decoded is! Map<String, dynamic>) return null;
    final id = decoded['id'];
    final payload = decoded['payload'];
    final seal = decoded['seal'];
    if (id is String && payload is String && seal is String) {
      return (id: id, payload: payload, seal: seal);
    }
    return null;
  } on FormatException {
    return null;
  }
}

/// Seeds golden sentinels into the RAG corpus under [immuneGoldenChatId] so a
/// [ContentIntegrityProbe] can retrieve them via the real semantic-search path.
///
/// Idempotent AND self-healing: seeds a golden only when no row for its id is
/// already present (checked via the same visibility query the probe reads
/// through), so a re-boot makes no embedding call and a vanished row is
/// re-seeded. One paid embed call per not-yet-seeded golden.
///
/// Only constructed when embeddings are enabled — the caller gates on
/// `env.voyageEnabled`.
class GoldenSeeder {
  GoldenSeeder({
    required EmbeddingClient client,
    required Queries queries,
    required SentinelSealer sealer,
    this.chatId = immuneGoldenChatId,
  })  : _client = client,
        _queries = queries,
        _sealer = sealer;

  final EmbeddingClient _client;
  final Queries _queries;
  final SentinelSealer _sealer;

  /// The reserved chatId golden rows are seeded under.
  final String chatId;

  /// Seeds each of [goldens] not already present. Returns the ids actually
  /// seeded this run (empty on a no-op re-seed).
  Future<List<String>> seed(List<Sentinel> goldens) async {
    final existingIds = <String>{
      for (final r in _queries.getVisibleMemories(chatId))
        if (parseSealedGolden(r.sourceText) case final p?) p.id,
    };
    final seeded = <String>[];
    for (final g in goldens) {
      if (existingIds.contains(g.id)) continue;
      final vec =
          (await _client.embed([g.payload], inputType: 'document')).first;
      _queries.insertMemoryEmbedding(
        chatId: chatId,
        sourceType: MemorySourceType.message,
        sourceText: jsonEncode(<String, String>{
          'id': g.id,
          'payload': g.payload,
          'seal': _sealer.seal(g),
        }),
        senderId: 'immune',
        senderName: 'immune',
        visibility: MemoryVisibility.sameChat,
        embedding: vec,
      );
      seeded.add(g.id);
    }
    return seeded;
  }
}

/// Builds the [SealedFetcher] the content probe uses: retrieve the golden via the
/// REAL memory-retrieval path (embed → getVisibleMemories → cosine → top-k),
/// scoped to [chatId], and parse `(payload, seal)` from the matching row.
///
/// Uses the retriever DIRECTLY (the RagProbe seam), not the deep_search tool
/// executor — the tool reads chatId from `registry.context`, which is null at
/// probe time. Each golden's payload is its own retrieval anchor, so the query
/// is byte-identical to the embedded text.
SealedFetcher buildGoldenFetcher({
  required MemoryRetriever retriever,
  List<Sentinel> goldens = immuneGoldens,
  String chatId = immuneGoldenChatId,
}) {
  final anchors = <String, String>{for (final g in goldens) g.id: g.payload};
  return (sentinelId) async {
    final anchor = anchors[sentinelId];
    if (anchor == null) return null;
    final results = await retriever.retrieve(anchor, chatId, topK: 10);
    for (final r in results) {
      final parsed = parseSealedGolden(r.record.sourceText);
      if (parsed != null && parsed.id == sentinelId) {
        return (payload: parsed.payload, seal: parsed.seal);
      }
    }
    return null;
  };
}
