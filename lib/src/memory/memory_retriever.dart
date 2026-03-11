/// Semantic memory retrieval via embedding similarity search.
///
/// [MemoryRetriever] is the bridge between working memory (the sliding window)
/// and long-term memory (the vector store). At query time, it:
/// 1. Embeds the user's message via [EmbeddingClient]
/// 2. Loads all visible embeddings from SQLite
/// 3. Computes cosine similarity (brute-force — fast at Dreamfinder's scale)
/// 4. Returns the top-k results above a similarity threshold
library;

import 'dart:developer' as developer;
import 'dart:math' as math;

import 'embedding_client.dart';
import 'memory_record.dart';

/// Default number of memory results to return.
const _defaultTopK = 5;

/// Default minimum cosine similarity threshold.
///
/// Below this, results are too dissimilar to be useful and would add noise
/// to the context window.
const _defaultMinScore = 0.3;

/// Callback type for loading visible memories from the database.
typedef LoadMemoriesFn = List<MemoryRecord> Function(String chatId);

/// Retrieves semantically relevant past conversations for context injection.
class MemoryRetriever {
  MemoryRetriever({
    required EmbeddingClient client,
    required LoadMemoriesFn loadMemories,
    int topK = _defaultTopK,
    double minScore = _defaultMinScore,
  })  : _client = client,
        _loadMemories = loadMemories,
        _topK = topK,
        _minScore = minScore;

  final EmbeddingClient _client;
  final LoadMemoriesFn _loadMemories;
  final int _topK;
  final double _minScore;

  /// Retrieves the most relevant memories for [query] in [chatId].
  ///
  /// Returns up to [_topK] results sorted by descending similarity score.
  /// Returns an empty list if embedding fails (graceful degradation).
  Future<List<MemorySearchResult>> retrieve(
    String query,
    String chatId,
  ) async {
    try {
      final queryEmbeddings = await _client.embed([query]);
      if (queryEmbeddings.isEmpty) return [];
      final queryVec = queryEmbeddings.first;

      final candidates = _loadMemories(chatId);
      if (candidates.isEmpty) return [];

      final scored = <MemorySearchResult>[];
      for (final record in candidates) {
        if (record.embedding == null) continue;
        final score = _cosineSimilarity(queryVec, record.embedding!);
        if (score >= _minScore) {
          scored.add(MemorySearchResult(record: record, score: score));
        }
      }

      // Sort descending by score.
      scored.sort((a, b) => b.score.compareTo(a.score));

      return scored.take(_topK).toList();
    } on Exception catch (e) {
      developer.log(
        'Memory retrieval failed: $e',
        name: 'MemoryRetriever',
        level: 900,
      );
      return [];
    }
  }

  /// Computes cosine similarity between two vectors.
  ///
  /// Returns a value in [-1, 1] where 1 means identical direction.
  /// Both vectors must have the same length.
  static double _cosineSimilarity(List<double> a, List<double> b) {
    assert(a.length == b.length, 'Vector lengths must match');

    var dot = 0.0;
    var normA = 0.0;
    var normB = 0.0;

    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }

    final denominator = math.sqrt(normA) * math.sqrt(normB);
    if (denominator == 0) return 0;

    return dot / denominator;
  }
}
