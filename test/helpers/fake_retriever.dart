/// Shared test fake for [MemoryRetriever].
///
/// Captures the last query and chatId for verification, and returns a
/// configurable list of [MemorySearchResult]s.
library;

import 'package:dreamfinder/src/memory/embedding_client.dart';
import 'package:dreamfinder/src/memory/memory_record.dart';
import 'package:dreamfinder/src/memory/memory_retriever.dart';

/// Fake [MemoryRetriever] that returns preconfigured results.
class FakeRetriever extends MemoryRetriever {
  FakeRetriever({this.results = const []})
      : super(client: _NullClient(), loadMemories: (_) => []);

  /// Results to return from [retrieve].
  final List<MemorySearchResult> results;

  /// The last query passed to [retrieve].
  String? lastQuery;

  /// The last chatId passed to [retrieve].
  String? lastChatId;

  /// The last topK passed to [retrieve].
  int? lastTopK;

  @override
  Future<List<MemorySearchResult>> retrieve(
    String query,
    String chatId, {
    int? topK,
    int? skipRecentMinutes,
  }) async {
    lastQuery = query;
    lastChatId = chatId;
    lastTopK = topK;
    return results.take(topK ?? results.length).toList();
  }
}

/// Stub [EmbeddingClient] for [FakeRetriever]'s super constructor.
class _NullClient implements EmbeddingClient {
  @override
  int get dimensions => 3;

  @override
  Future<List<List<double>>> embed(
    List<String> texts, {
    String inputType = 'document',
  }) async =>
      [];
}
