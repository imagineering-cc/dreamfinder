/// Shared test fakes for the embedding pipeline.
///
/// Provides [FakePipeline], [NullEmbeddingClient], and [NullQueries] so that
/// tests verifying memory visibility or tool behavior don't duplicate stubs.
library;

import 'package:dreamfinder/src/memory/embedding_client.dart';
import 'package:dreamfinder/src/memory/embedding_pipeline.dart';
import 'package:dreamfinder/src/memory/memory_record.dart';

/// Fake [EmbeddingPipeline] that captures [queue] calls for verification.
class FakePipeline extends EmbeddingPipeline {
  FakePipeline()
      : super(client: NullEmbeddingClient(), queries: NullQueries());

  /// All calls made to [queue], in order.
  final List<QueueCall> calls = [];

  @override
  void queue({
    required String chatId,
    required String userText,
    required String assistantText,
    String? senderUuid,
    String? senderName,
    MemoryVisibility visibility = MemoryVisibility.sameChat,
  }) {
    calls.add(QueueCall(
      chatId: chatId,
      userText: userText,
      assistantText: assistantText,
      senderUuid: senderUuid,
      senderName: senderName,
      visibility: visibility,
    ));
  }
}

/// A captured call to [EmbeddingPipeline.queue].
class QueueCall {
  const QueueCall({
    required this.chatId,
    required this.userText,
    required this.assistantText,
    this.senderUuid,
    this.senderName,
    required this.visibility,
  });

  final String chatId;
  final String userText;
  final String assistantText;
  final String? senderUuid;
  final String? senderName;
  final MemoryVisibility visibility;
}

/// Stub [EmbeddingClient] that returns empty results.
class NullEmbeddingClient implements EmbeddingClient {
  @override
  int get dimensions => 512;

  @override
  Future<List<List<double>>> embed(
    List<String> texts, {
    String inputType = 'document',
  }) async =>
      [];
}

/// Stub [MemoryQueryAccessor] that does nothing.
class NullQueries implements MemoryQueryAccessor {
  @override
  int insertMemoryEmbedding({
    int? messageId,
    required String chatId,
    required MemorySourceType sourceType,
    required String sourceText,
    String? senderUuid,
    String? senderName,
    MemoryVisibility visibility = MemoryVisibility.sameChat,
    List<double>? embedding,
  }) =>
      0;

  @override
  void updateMemoryEmbedding(int id, List<double> embedding) {}
}
