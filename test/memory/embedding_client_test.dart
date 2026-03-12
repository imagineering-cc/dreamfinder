import 'dart:convert';

import 'package:dreamfinder/src/memory/embedding_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

void main() {
  group('VoyageEmbeddingClient', () {
    test('sends correct request to Voyage API', () async {
      String? capturedBody;
      Map<String, String>? capturedHeaders;

      final mockClient = http_testing.MockClient((request) async {
        capturedBody = request.body;
        capturedHeaders = request.headers;

        return http.Response(
          jsonEncode({
            'data': [
              {
                'index': 0,
                'embedding': List.filled(512, 0.1),
              },
            ],
          }),
          200,
        );
      });

      final client = VoyageEmbeddingClient(
        apiKey: 'test-key',
        httpClient: mockClient,
      );

      await client.embed(['Hello world']);

      expect(capturedHeaders!['Authorization'], equals('Bearer test-key'));
      expect(capturedHeaders!['Content-Type'], equals('application/json'));

      final body = jsonDecode(capturedBody!) as Map<String, dynamic>;
      expect(body['model'], equals('voyage-3-lite'));
      expect(body['input'], equals(['Hello world']));
      expect(body['input_type'], equals('document'));
    });

    test('passes inputType to API request', () async {
      String? capturedBody;

      final mockClient = http_testing.MockClient((request) async {
        capturedBody = request.body;
        return http.Response(
          jsonEncode({
            'data': [
              {'index': 0, 'embedding': List.filled(512, 0.1)},
            ],
          }),
          200,
        );
      });

      final client = VoyageEmbeddingClient(
        apiKey: 'test-key',
        httpClient: mockClient,
      );

      await client.embed(['search query'], inputType: 'query');

      final body = jsonDecode(capturedBody!) as Map<String, dynamic>;
      expect(body['input_type'], equals('query'));
    });

    test('returns embeddings in input order', () async {
      final mockClient = http_testing.MockClient((request) async {
        // Simulate out-of-order response.
        return http.Response(
          jsonEncode({
            'data': [
              {
                'index': 1,
                'embedding': List.filled(512, 0.2),
              },
              {
                'index': 0,
                'embedding': List.filled(512, 0.1),
              },
            ],
          }),
          200,
        );
      });

      final client = VoyageEmbeddingClient(
        apiKey: 'test-key',
        httpClient: mockClient,
      );

      final result = await client.embed(['first', 'second']);

      expect(result.length, equals(2));
      // First input should map to 0.1 embeddings, second to 0.2.
      expect(result[0][0], closeTo(0.1, 0.001));
      expect(result[1][0], closeTo(0.2, 0.001));
    });

    test('returns empty list for empty input', () async {
      final mockClient = http_testing.MockClient((request) async {
        fail('Should not make API call for empty input');
        // Unreachable but needed for type.
      });

      final client = VoyageEmbeddingClient(
        apiKey: 'test-key',
        httpClient: mockClient,
      );

      final result = await client.embed([]);
      expect(result, isEmpty);
    });

    test('throws EmbeddingException on API error', () async {
      final mockClient = http_testing.MockClient((request) async {
        return http.Response('{"error": "rate limited"}', 429);
      });

      final client = VoyageEmbeddingClient(
        apiKey: 'test-key',
        httpClient: mockClient,
      );

      expect(
        () => client.embed(['test']),
        throwsA(isA<EmbeddingException>()),
      );
    });

    test('reports 512 dimensions', () {
      final client = VoyageEmbeddingClient(apiKey: 'test-key');
      expect(client.dimensions, equals(512));
    });
  });
}
