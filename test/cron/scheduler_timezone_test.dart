import 'package:dreamfinder/src/cron/scheduler.dart';
import 'package:dreamfinder/src/db/database.dart';
import 'package:dreamfinder/src/db/queries.dart';
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

  group('Scheduler timezone support', () {
    test('fires prompt at configured hour in AEST timezone', () async {
      queries.upsertStandupConfig(
        signalGroupId: 'group-1',
        promptHour: 9,
        timezone: 'Australia/Melbourne',
      );

      final sentMessages = <MapEntry<String, String>>[];
      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {
          sentMessages.add(MapEntry(groupId, message));
        },
      );

      // 2026-03-02 is a Monday.
      // 9:00 AEDT = 22:00 UTC the previous day (March 1).
      // Server time is UTC, so pass UTC time that corresponds to 9am Melbourne.
      await scheduler.tick(DateTime.utc(2026, 3, 1, 22, 0));

      expect(sentMessages, hasLength(1));
      expect(sentMessages.first.key, equals('group-1'));
    });

    test('does not fire when UTC hour matches but local hour does not',
        () async {
      queries.upsertStandupConfig(
        signalGroupId: 'group-1',
        promptHour: 9,
        timezone: 'Australia/Melbourne',
      );

      final sentMessages = <MapEntry<String, String>>[];
      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {
          sentMessages.add(MapEntry(groupId, message));
        },
      );

      // 9:00 UTC = 20:00 AEDT — not prompt hour in Melbourne.
      await scheduler.tick(DateTime.utc(2026, 3, 2, 9, 0));

      expect(sentMessages, isEmpty);
    });

    test('weekend check uses local timezone', () async {
      queries.upsertStandupConfig(
        signalGroupId: 'group-1',
        promptHour: 9,
        timezone: 'Australia/Melbourne',
        skipWeekends: true,
      );

      final sentMessages = <MapEntry<String, String>>[];
      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {
          sentMessages.add(MapEntry(groupId, message));
        },
      );

      // 2026-03-06 is a Friday in UTC.
      // But 2026-03-06 22:00 UTC = 2026-03-07 09:00 AEDT (Saturday).
      // Should NOT send because it's Saturday in Melbourne.
      await scheduler.tick(DateTime.utc(2026, 3, 6, 22, 0));

      expect(sentMessages, isEmpty);
    });

    test('date string uses local timezone for session dedup', () async {
      queries.upsertStandupConfig(
        signalGroupId: 'group-1',
        promptHour: 9,
        timezone: 'Australia/Melbourne',
      );

      final sentMessages = <MapEntry<String, String>>[];
      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {
          sentMessages.add(MapEntry(groupId, message));
        },
      );

      // 2026-03-01 22:00 UTC = 2026-03-02 09:00 AEDT.
      // Session should be stored under the local date (2026-03-02).
      await scheduler.tick(DateTime.utc(2026, 3, 1, 22, 0));

      expect(sentMessages, hasLength(1));

      // Session should exist for the local date.
      final session = queries.getActiveStandupSession('group-1', '2026-03-02');
      expect(session, isNotNull);

      // No session for the UTC date.
      final utcSession =
          queries.getActiveStandupSession('group-1', '2026-03-01');
      expect(utcSession, isNull);
    });

    test('handles US timezone correctly', () async {
      queries.upsertStandupConfig(
        signalGroupId: 'group-us',
        promptHour: 9,
        timezone: 'America/New_York',
      );

      final sentMessages = <MapEntry<String, String>>[];
      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {
          sentMessages.add(MapEntry(groupId, message));
        },
      );

      // 2026-03-02 14:00 UTC = 2026-03-02 09:00 EST.
      await scheduler.tick(DateTime.utc(2026, 3, 2, 14, 0));

      expect(sentMessages, hasLength(1));
    });

    test('falls back to UTC for invalid timezone', () async {
      queries.upsertStandupConfig(
        signalGroupId: 'group-1',
        promptHour: 9,
        timezone: 'Invalid/Timezone',
      );

      final sentMessages = <MapEntry<String, String>>[];
      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {
          sentMessages.add(MapEntry(groupId, message));
        },
      );

      // 9:00 UTC — should match since invalid timezone falls back to UTC.
      await scheduler.tick(DateTime.utc(2026, 3, 2, 9, 0));

      expect(sentMessages, hasLength(1));
    });
  });
}
