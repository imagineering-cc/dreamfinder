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

  /// Seeds each of [goldens] not already present as a CURRENT sealed row.
  /// Returns the ids actually seeded this run (empty on a no-op re-seed).
  ///
  /// Admission predicate (measurement-integrity): a golden counts as present
  /// only if a row in the IMMUNE-OWNED compartment ([chatId], `same_chat`)
  /// parses to the same id, carries the same payload, AND verifies under the
  /// CURRENT sealer. This is deliberately NOT "an id exists":
  ///
  /// * The lookup is [Queries.getEmbeddedMemories] scoped to [chatId] — NOT
  ///   `getVisibleMemories`, which also returns user/tool-writable `cross_chat`
  ///   rows, letting a planted `{"id":"…golden…"}` row suppress the real seed
  ///   (a denial-of-seed lever, and it would silently kill self-healing).
  /// * A row with the right id but a stale/forged/wrong-key payload does NOT
  ///   satisfy the predicate — it is PURGED and the golden re-seeded. This heals
  ///   a corrupt write, a key rotation (old seal no longer verifies), and a
  ///   version bump (the seal is over id+payload+version, so a bumped version
  ///   fails verification) without a manual delete.
  ///
  /// Not covered (named for PR2c): an embedding-model/dimension cutover leaves a
  /// verifying row with a stale vector — the seal is over text, not the vector —
  /// so it is treated as current. That needs an embedding-fingerprint, tracked
  /// with the rest of the rotation/retirement mechanism.
  Future<List<String>> seed(List<Sentinel> goldens) async {
    final seeded = <String>[];
    for (final g in goldens) {
      final rows = _queries.getEmbeddedMemories(
        chatId: chatId,
        visibilities: const [MemoryVisibility.sameChat],
      );
      final stale = <int>[];
      var current = false;
      for (final r in rows) {
        final p = parseSealedGolden(r.sourceText);
        if (p == null || p.id != g.id) continue;
        if (p.payload == g.payload && _sealer.verify(g, p.seal)) {
          current = true;
        } else {
          stale.add(r.id);
        }
      }
      if (stale.isNotEmpty) _queries.deleteMemoryEmbeddings(stale);
      if (current) continue;
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
      // The retriever reads through getVisibleMemories, which also returns
      // user/tool-writable `cross_chat` rows — reject anything not in the
      // immune-owned compartment so a planted `cross_chat` decoy with the
      // golden's id can't be handed to the probe (it would force a false page).
      if (r.record.chatId != chatId) continue;
      final parsed = parseSealedGolden(r.record.sourceText);
      if (parsed != null && parsed.id == sentinelId) {
        return (payload: parsed.payload, seal: parsed.seal);
      }
    }
    return null;
  };
}
