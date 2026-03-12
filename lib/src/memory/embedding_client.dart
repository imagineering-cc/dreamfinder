/// Embedding client abstraction and Voyage AI implementation.
///
/// The [EmbeddingClient] interface decouples the memory system from any
/// specific embedding provider. [VoyageEmbeddingClient] implements it using
/// Voyage AI's REST API (`voyage-3-lite`, 512 dimensions).
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

/// Abstract interface for generating text embeddings.
///
/// Implementations must return a list of float vectors, one per input text.
/// Each vector has a fixed dimensionality determined by the model.
abstract class EmbeddingClient {
  /// Embeds a list of texts and returns their vector representations.
  ///
  /// Each inner list is a float vector of length [dimensions].
  /// [inputType] controls how the embedding model treats the input:
  /// - `'document'` for content being stored (default)
  /// - `'query'` for search queries used in retrieval
  Future<List<List<double>>> embed(
    List<String> texts, {
    String inputType = 'document',
  });

  /// The dimensionality of the embedding vectors.
  int get dimensions;
}

/// Voyage AI embedding client using the `voyage-3-lite` model.
///
/// [voyage-3-lite](https://docs.voyageai.com/docs/embeddings) produces
/// 512-dimensional vectors optimized for retrieval. The REST API is a single
/// POST endpoint — no SDK dependency needed.
class VoyageEmbeddingClient implements EmbeddingClient {
  VoyageEmbeddingClient({
    required String apiKey,
    http.Client? httpClient,
    this.model = 'voyage-3-lite',
  })  : _apiKey = apiKey,
        _httpClient = httpClient ?? http.Client();

  final String _apiKey;
  final http.Client _httpClient;

  /// The Voyage AI model to use. Defaults to `voyage-3-lite`.
  final String model;

  static const _baseUrl = 'https://api.voyageai.com/v1';

  @override
  int get dimensions => 512;

  @override
  Future<List<List<double>>> embed(
    List<String> texts, {
    String inputType = 'document',
  }) async {
    if (texts.isEmpty) return [];

    final response = await _httpClient.post(
      Uri.parse('$_baseUrl/embeddings'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_apiKey',
      },
      body: jsonEncode({
        'model': model,
        'input': texts,
        'input_type': inputType,
      }),
    );

    if (response.statusCode != 200) {
      throw EmbeddingException(
        'Voyage API error ${response.statusCode}: ${response.body}',
      );
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final data = json['data'] as List<dynamic>;

    // Sort by index to maintain input order (API may return out of order).
    final sorted = List<Map<String, dynamic>>.from(
      data.cast<Map<String, dynamic>>(),
    )..sort(
        (a, b) => (a['index'] as int).compareTo(b['index'] as int),
      );

    return [
      for (final item in sorted)
        (item['embedding'] as List<dynamic>).cast<num>().map((n) => n.toDouble()).toList(),
    ];
  }
}

/// Exception thrown when an embedding API call fails.
class EmbeddingException implements Exception {
  const EmbeddingException(this.message);
  final String message;

  @override
  String toString() => 'EmbeddingException: $message';
}
