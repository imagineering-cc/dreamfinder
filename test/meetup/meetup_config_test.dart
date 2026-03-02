import 'package:imagineering_pm_bot/src/meetup/meetup_config.dart';
import 'package:test/test.dart';

void main() {
  group('MeetupConfig', () {
    test('has sensible defaults', () {
      const config =
          MeetupConfig(meetLink: 'https://meet.google.com/abc-defg-hij');

      expect(config.meetLink, 'https://meet.google.com/abc-defg-hij');
      expect(config.displayName, 'Dreamfinder');
      expect(config.participants, isEmpty);
      expect(config.sprintDuration, const Duration(minutes: 25));
      expect(config.breakDuration, const Duration(minutes: 10));
      expect(config.introDuration, const Duration(seconds: 60));
      expect(config.demoDuration, const Duration(seconds: 60));
      expect(config.sprintCount, 3);
      expect(config.introTotalDuration, const Duration(minutes: 5));
      expect(config.demoTotalDuration, const Duration(minutes: 5));
    });

    test('accepts custom values', () {
      const config = MeetupConfig(
        meetLink: 'https://meet.google.com/custom',
        displayName: 'Test Bot',
        participants: ['Alice', 'Bob', 'Charlie'],
        sprintDuration: Duration(minutes: 15),
        breakDuration: Duration(minutes: 5),
        sprintCount: 2,
      );

      expect(config.displayName, 'Test Bot');
      expect(config.participants, ['Alice', 'Bob', 'Charlie']);
      expect(config.sprintDuration, const Duration(minutes: 15));
      expect(config.breakDuration, const Duration(minutes: 5));
      expect(config.sprintCount, 2);
    });

    test('preserves participant order', () {
      const config = MeetupConfig(
        meetLink: 'https://meet.google.com/test',
        participants: ['Zara', 'Alice', 'Mike'],
      );

      expect(config.participants[0], 'Zara');
      expect(config.participants[1], 'Alice');
      expect(config.participants[2], 'Mike');
    });
  });
}
