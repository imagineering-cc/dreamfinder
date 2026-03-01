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
  });
}
