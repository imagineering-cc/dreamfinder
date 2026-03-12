import 'package:dreamfinder/src/memory/summarization_client.dart';
import 'package:test/test.dart';

void main() {
  group('SummarizationClient', () {
    test('joins source texts and calls callback with correct prompt', () async {
      String? capturedPrompt;
      final client = SummarizationClient(
        createSummarization: (prompt) async {
          capturedPrompt = prompt;
          return 'Summary of conversation';
        },
      );

      final result = await client.summarize([
        'Nick: What is the Dawn Gate?\nDreamfinder: It is an emoji gateway.',
        'Nick: Who built it?\nDreamfinder: I created it spontaneously.',
      ]);

      expect(result, equals('Summary of conversation'));
      expect(capturedPrompt, isNotNull);
      expect(capturedPrompt, contains('Dawn Gate'));
      expect(capturedPrompt, contains('Who built it'));
      expect(capturedPrompt, contains('---'));
      expect(
        capturedPrompt,
        contains('Summarize'),
        reason: 'Prompt should instruct the model to summarize',
      );
    });

    test('handles single source text', () async {
      String? capturedPrompt;
      final client = SummarizationClient(
        createSummarization: (prompt) async {
          capturedPrompt = prompt;
          return 'Single summary';
        },
      );

      final result = await client.summarize(['Only one message here.']);

      expect(result, equals('Single summary'));
      expect(capturedPrompt, contains('Only one message here.'));
      // Should not contain separator when there's only one text.
      expect(capturedPrompt, isNot(contains('---')));
    });

    test('returns empty string for empty input', () async {
      var callbackCalled = false;
      final client = SummarizationClient(
        createSummarization: (prompt) async {
          callbackCalled = true;
          return 'Should not be called';
        },
      );

      final result = await client.summarize([]);

      expect(result, isEmpty);
      expect(callbackCalled, isFalse);
    });

    test('propagates callback exceptions', () async {
      final client = SummarizationClient(
        createSummarization: (prompt) async {
          throw Exception('API rate limit exceeded');
        },
      );

      expect(
        () => client.summarize(['Some text']),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('API rate limit exceeded'),
        )),
      );
    });
  });
}
