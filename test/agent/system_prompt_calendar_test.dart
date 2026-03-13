import 'package:dreamfinder/src/agent/agent_loop.dart';
import 'package:dreamfinder/src/agent/system_prompt.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:test/test.dart';

void main() {
  setUpAll(() => tzdata.initializeTimeZones());

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
          start: '2026-03-13T23:00:00.000Z',
          end: '2026-03-14T04:30:00.000Z',
          location: 'Southern Cross Station',
        ),
        const CalendarEvent(
          summary: "Round 3: We're getting there!",
          start: '2026-03-28T08:00:00.000Z',
          end: '2026-03-28T10:00:00.000Z',
          location: 'The Abode, 318 Russell St',
        ),
      ];

      final prompt = buildSystemPrompt(
        input,
        events: events,
        eventTimeZone: 'Australia/Melbourne',
      );

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
          start: '2026-05-23T09:00:00.000Z',
          end: '2026-05-23T11:00:00.000Z',
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
          start: '2026-03-13T22:00:00.000Z',
          end: '2026-03-13T22:15:00.000Z',
        ),
      ];

      final prompt = buildSystemPrompt(systemInput, events: events);

      final eventsIndex = prompt.indexOf('## Upcoming Events');
      final reminderIndex = prompt.indexOf('## System-Initiated Reminder');
      expect(eventsIndex, lessThan(reminderIndex));
    });

    test('applies IANA timezone to display times', () {
      // Event at 2026-03-13T23:00:00Z = 2026-03-14T10:00:00 AEDT
      final events = [
        const CalendarEvent(
          summary: 'Bendigo Day Trip',
          start: '2026-03-13T23:00:00.000Z',
        ),
      ];

      final prompt = buildSystemPrompt(
        input,
        events: events,
        eventTimeZone: 'Australia/Melbourne',
      );

      // Should show local date/time (Mar 14 at 10:00), not UTC (Mar 13 at 23:00).
      expect(prompt, contains('[2026-03-14 10:00]'));
      expect(prompt, isNot(contains('23:00')));
    });

    test('defaults to UTC when no timezone provided', () {
      final events = [
        const CalendarEvent(
          summary: 'Bendigo Day Trip',
          start: '2026-03-13T23:00:00.000Z',
        ),
      ];

      final prompt = buildSystemPrompt(input, events: events);

      expect(prompt, contains('[2026-03-13 23:00]'));
    });

    test('handles DST transitions correctly', () {
      // April 5, 2026 — AEST (+10) not AEDT (+11).
      // 2026-04-04T23:00:00Z = 2026-04-05T09:00:00 AEST.
      final events = [
        const CalendarEvent(
          summary: 'Post-DST Event',
          start: '2026-04-04T23:00:00.000Z',
        ),
      ];

      final prompt = buildSystemPrompt(
        input,
        events: events,
        eventTimeZone: 'Australia/Melbourne',
      );

      expect(prompt, contains('[2026-04-05 09:00]'));
    });

    test('skips events with malformed start dates', () {
      final events = [
        const CalendarEvent(
          summary: 'Good Event',
          start: '2026-03-14T10:00:00.000Z',
        ),
        const CalendarEvent(
          summary: 'Bad Event',
          start: 'not-a-date',
        ),
      ];

      final prompt = buildSystemPrompt(input, events: events);

      expect(prompt, contains('Good Event'));
      expect(prompt, isNot(contains('Bad Event')));
    });

    test('falls back to UTC for invalid timezone', () {
      final events = [
        const CalendarEvent(
          summary: 'Test Event',
          start: '2026-03-13T23:00:00.000Z',
        ),
      ];

      final prompt = buildSystemPrompt(
        input,
        events: events,
        eventTimeZone: 'Invalid/Timezone',
      );

      // Should show UTC time since timezone is invalid.
      expect(prompt, contains('[2026-03-13 23:00]'));
    });
  });
}
