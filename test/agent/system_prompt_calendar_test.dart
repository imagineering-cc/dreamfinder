import 'package:dreamfinder/src/agent/agent_loop.dart';
import 'package:dreamfinder/src/agent/system_prompt.dart';
import 'package:test/test.dart';

void main() {
  group('buildSystemPrompt — calendar events', () {
    const input = AgentInput(
      text: 'What do we have coming up?',
      chatId: 'group-1',
      senderUuid: 'user-1',
      senderName: 'Nick',
      isAdmin: true,
    );

    test('includes Upcoming Events section when events provided', () {
      final events = [
        const CalendarEvent(
          summary: 'Bendigo Day Trip',
          start: '2026-03-14T10:00:00+11:00',
          end: '2026-03-14T15:30:00+11:00',
          location: 'Southern Cross Station',
        ),
        const CalendarEvent(
          summary: "Round 3: We're getting there!",
          start: '2026-03-28T19:00:00+11:00',
          end: '2026-03-28T21:00:00+11:00',
          location: 'The Abode, 318 Russell St',
        ),
      ];

      final prompt = buildSystemPrompt(input, events: events);

      expect(prompt, contains('## Upcoming Events'));
      expect(prompt, contains('Bendigo Day Trip'));
      expect(prompt, contains('Southern Cross Station'));
      expect(prompt, contains("Round 3: We're getting there!"));
      expect(prompt, contains('The Abode'));
      expect(prompt, contains('Reference them naturally'));
    });

    test('omits Upcoming Events section when no events', () {
      final prompt = buildSystemPrompt(input);
      expect(prompt, isNot(contains('Upcoming Events')));
    });

    test('shows event without location gracefully', () {
      final events = [
        const CalendarEvent(
          summary: 'Round 2.1',
          start: '2026-05-23T19:00:00+10:00',
          end: '2026-05-23T21:00:00+10:00',
        ),
      ];

      final prompt = buildSystemPrompt(input, events: events);

      expect(prompt, contains('Round 2.1'));
      expect(prompt, isNot(contains('null')));
    });

    test('events section appears before System-Initiated Reminder', () {
      const systemInput = AgentInput(
        text: 'standup prompt',
        chatId: 'group-1',
        senderUuid: 'system',
        isAdmin: true,
        isSystemInitiated: true,
      );
      final events = [
        const CalendarEvent(
          summary: 'Standup',
          start: '2026-03-14T09:00:00+11:00',
          end: '2026-03-14T09:15:00+11:00',
        ),
      ];

      final prompt = buildSystemPrompt(systemInput, events: events);

      final eventsIndex = prompt.indexOf('## Upcoming Events');
      final reminderIndex = prompt.indexOf('## System-Initiated Reminder');
      expect(eventsIndex, lessThan(reminderIndex));
    });
  });
}
