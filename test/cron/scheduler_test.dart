import 'package:imagineering_pm_bot/src/cron/scheduler.dart';
import 'package:imagineering_pm_bot/src/db/database.dart';
import 'package:imagineering_pm_bot/src/db/queries.dart';
import 'package:test/test.dart';

void main() {
  late BotDatabase db;
  late Queries queries;

  setUp(() {
    db = BotDatabase.inMemory();
    queries = Queries(db);
  });

  tearDown(() {
    db.close();
  });

  group('Scheduler', () {
    test('can be created and stopped without error', () {
      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {},
      );
      scheduler.start();
      scheduler.stop();
    });

    test('does not throw when no standup configs exist', () async {
      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {},
      );

      // Manually trigger tick — no configs means no work.
      await scheduler.tick(DateTime(2026, 3, 2, 9, 0));
    });
  });

  group('Scheduler standup prompts', () {
    test('sends prompt at configured hour', () async {
      queries.upsertStandupConfig(
        signalGroupId: 'group-1',
        promptHour: 9,
      );

      final sentMessages = <MapEntry<String, String>>[];
      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {
          sentMessages.add(MapEntry(groupId, message));
        },
      );

      // 9:00 AM — prompt hour.
      await scheduler.tick(DateTime(2026, 3, 2, 9, 0));

      expect(sentMessages, hasLength(1));
      expect(sentMessages.first.key, equals('group-1'));
      expect(sentMessages.first.value, contains('standup'));
    });

    test('does not send prompt if already sent today', () async {
      queries.upsertStandupConfig(
        signalGroupId: 'group-1',
        promptHour: 9,
      );

      final sentMessages = <MapEntry<String, String>>[];
      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {
          sentMessages.add(MapEntry(groupId, message));
        },
      );

      // First tick creates the session and sends the prompt.
      await scheduler.tick(DateTime(2026, 3, 2, 9, 0));
      expect(sentMessages, hasLength(1));

      // Second tick at same hour — should not re-send.
      await scheduler.tick(DateTime(2026, 3, 2, 9, 30));
      expect(sentMessages, hasLength(1));
    });

    test('skips disabled groups', () async {
      queries.upsertStandupConfig(
        signalGroupId: 'group-1',
        enabled: false,
      );

      final sentMessages = <MapEntry<String, String>>[];
      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {
          sentMessages.add(MapEntry(groupId, message));
        },
      );

      await scheduler.tick(DateTime(2026, 3, 2, 9, 0));
      expect(sentMessages, isEmpty);
    });

    test('skips weekends when configured', () async {
      queries.upsertStandupConfig(
        signalGroupId: 'group-1',
        promptHour: 9,
        skipWeekends: true,
      );

      final sentMessages = <MapEntry<String, String>>[];
      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {
          sentMessages.add(MapEntry(groupId, message));
        },
      );

      // Saturday March 7, 2026.
      await scheduler.tick(DateTime(2026, 3, 7, 9, 0));
      expect(sentMessages, isEmpty);
    });
  });

  group('Scheduler agent composition', () {
    test('uses composeViaAgent when provided', () async {
      queries.upsertStandupConfig(
        signalGroupId: 'group-1',
        promptHour: 9,
      );

      final sentMessages = <MapEntry<String, String>>[];
      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {
          sentMessages.add(MapEntry(groupId, message));
        },
        composeViaAgent: (groupId, taskDescription) async {
          return 'Rise and shine, team! What are you working on today?';
        },
      );

      await scheduler.tick(DateTime(2026, 3, 2, 9, 0));

      expect(sentMessages, hasLength(1));
      expect(sentMessages.first.value, equals(
        'Rise and shine, team! What are you working on today?',
      ));
    });

    test('falls back to hardcoded message when composeViaAgent throws',
        () async {
      queries.upsertStandupConfig(
        signalGroupId: 'group-1',
        promptHour: 9,
      );

      final sentMessages = <MapEntry<String, String>>[];
      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {
          sentMessages.add(MapEntry(groupId, message));
        },
        composeViaAgent: (groupId, taskDescription) async {
          throw Exception('Claude API is down');
        },
      );

      await scheduler.tick(DateTime(2026, 3, 2, 9, 0));

      expect(sentMessages, hasLength(1));
      expect(sentMessages.first.value, equals(Scheduler.hardcodedStandupPrompt));

      // Session should still be created despite the agent failure.
      final session = queries.getActiveStandupSession('group-1', '2026-03-02');
      expect(session, isNotNull);
    });

    test('falls back to hardcoded message when composeViaAgent returns empty',
        () async {
      queries.upsertStandupConfig(
        signalGroupId: 'group-1',
        promptHour: 9,
      );

      final sentMessages = <MapEntry<String, String>>[];
      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {
          sentMessages.add(MapEntry(groupId, message));
        },
        composeViaAgent: (groupId, taskDescription) async {
          return '';
        },
      );

      await scheduler.tick(DateTime(2026, 3, 2, 9, 0));

      expect(sentMessages, hasLength(1));
      expect(
          sentMessages.first.value, equals(Scheduler.hardcodedStandupPrompt));
    });

    test('sends hardcoded message when composeViaAgent is null', () async {
      queries.upsertStandupConfig(
        signalGroupId: 'group-1',
        promptHour: 9,
      );

      final sentMessages = <MapEntry<String, String>>[];
      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {
          sentMessages.add(MapEntry(groupId, message));
        },
        // No composeViaAgent provided.
      );

      await scheduler.tick(DateTime(2026, 3, 2, 9, 0));

      expect(sentMessages, hasLength(1));
      expect(sentMessages.first.value, equals(Scheduler.hardcodedStandupPrompt));
    });
  });

  group('Scheduler old data cleanup', () {
    test('cleanOldData removes old reminders and calendar reminders', () {
      // Insert an old reminder.
      queries.upsertReminder('card-old', 'group-1');
      // Force the reminder timestamp to be 30 days ago.
      db.handle.execute(
        "UPDATE sent_reminders SET last_reminder_at = datetime('now', '-30 days')",
      );

      // Insert an old calendar reminder.
      queries.recordCalendarReminder('event-old', 'group-1',
          CalendarReminderWindow.twentyFourHours);
      db.handle.execute(
        "UPDATE calendar_reminders SET sent_at = datetime('now', '-30 days')",
      );

      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {},
      );
      scheduler.cleanOldData();

      expect(queries.getLastReminder('card-old', 'group-1'), isNull);
      expect(
        queries.hasCalendarReminderBeenSent(
          'event-old', 'group-1', CalendarReminderWindow.twentyFourHours),
        isFalse,
      );
    });

    test('tick triggers cleanup once per day after 3 AM', () async {
      // Insert old data to verify cleanup runs.
      queries.upsertReminder('card-old', 'group-1');
      db.handle.execute(
        "UPDATE sent_reminders SET last_reminder_at = datetime('now', '-30 days')",
      );

      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {},
      );

      // Tick at 3:15 AM — should trigger cleanup.
      await scheduler.tick(DateTime(2026, 3, 2, 3, 15));
      expect(queries.getLastReminder('card-old', 'group-1'), isNull);

      // Insert new old data.
      queries.upsertReminder('card-old-2', 'group-1');
      db.handle.execute(
        "UPDATE sent_reminders SET last_reminder_at = datetime('now', '-30 days') "
        "WHERE card_public_id = 'card-old-2'",
      );

      // Tick again same day at 4 AM — should NOT re-run cleanup.
      await scheduler.tick(DateTime(2026, 3, 2, 4, 0));
      expect(queries.getLastReminder('card-old-2', 'group-1'), isNotNull);

      // Tick next day at 3:00 AM — should trigger cleanup again.
      await scheduler.tick(DateTime(2026, 3, 3, 3, 0));
      expect(queries.getLastReminder('card-old-2', 'group-1'), isNull);
    });

    test('tick does not trigger cleanup before 3 AM', () async {
      queries.upsertReminder('card-old', 'group-1');
      db.handle.execute(
        "UPDATE sent_reminders SET last_reminder_at = datetime('now', '-30 days')",
      );

      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {},
      );

      // Tick at 2:59 AM — too early, no cleanup.
      await scheduler.tick(DateTime(2026, 3, 2, 2, 59));
      expect(queries.getLastReminder('card-old', 'group-1'), isNotNull);
    });
  });
}
