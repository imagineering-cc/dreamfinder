import 'package:imagineering_pm_bot/src/meetup/caption_entry.dart';
import 'package:test/test.dart';

void main() {
  group('CaptionEntry', () {
    test('fromBrowserJson parses all fields', () {
      final entry = CaptionEntry.fromBrowserJson({
        'speaker': 'Alice',
        'text': 'Hello everyone',
        'timestamp': 1234567890,
      });

      expect(entry.speaker, 'Alice');
      expect(entry.text, 'Hello everyone');
      expect(entry.timestamp, 1234567890);
    });

    test('fromBrowserJson defaults missing speaker to empty string', () {
      final entry = CaptionEntry.fromBrowserJson({
        'text': 'Some text',
        'timestamp': 100,
      });

      expect(entry.speaker, '');
      expect(entry.text, 'Some text');
    });

    test('fromBrowserJson defaults missing text to empty string', () {
      final entry = CaptionEntry.fromBrowserJson({
        'speaker': 'Bob',
        'timestamp': 200,
      });

      expect(entry.speaker, 'Bob');
      expect(entry.text, '');
    });

    test('fromBrowserJson defaults missing timestamp to 0', () {
      final entry = CaptionEntry.fromBrowserJson({
        'speaker': 'Charlie',
        'text': 'Hi',
      });

      expect(entry.timestamp, 0);
    });

    test('toString includes all fields', () {
      const entry = CaptionEntry(
        speaker: 'Alice',
        text: 'Hello',
        timestamp: 42,
      );

      final str = entry.toString();
      expect(str, contains('Alice'));
      expect(str, contains('Hello'));
      expect(str, contains('42'));
    });
  });
}
