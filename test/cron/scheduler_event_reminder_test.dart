import 'package:dreamfinder/src/cron/scheduler.dart';
import 'package:dreamfinder/src/db/database.dart';
import 'package:dreamfinder/src/db/queries.dart';
import 'package:test/test.dart';

/// Tests for the weekly Imagineering "session starts in 5 minutes" reminder.
///
/// The session runs Saturdays at 15:00 Australia/Melbourne; the reminder fires
/// 5 minutes earlier at 14:55 local. Melbourne is UTC+10 in June (AEST, no
/// DST), so Saturday 14:55 local == Saturday 04:55 UTC for these dates.
///
/// Venue alternates weekly off the 2026-06-20 = ONLINE anchor:
///   2026-06-20 Sat -> online, 2026-06-27 Sat -> in-person,
///   2026-07-04 Sat -> online, ...
void main() {
  late BotDatabase db;
  late Queries queries;

  setUp(() {
    db = BotDatabase.inMemory();
    queries = Queries(db);
  });

  tearDown(() => db.close());

  // Saturday 14:55 Melbourne == 04:55 UTC.
  final inPersonSaturday = DateTime.utc(2026, 6, 27, 4, 55); // in-person week
  final onlineSaturday = DateTime.utc(2026, 7, 4, 4, 55); // online week

  Scheduler buildScheduler(
    List<MapEntry<String, String>> sink, {
    String? roomId = '!imagineering-portal:imagineering.cc',
  }) =>
      Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {
          sink.add(MapEntry(groupId, message));
        },
        eventReminderRoomId: roomId,
      );

  group('isOnlineEventWeek parity', () {
    test('anchor week and every even week is online', () {
      final s = buildScheduler([]);
      expect(s.isOnlineEventWeek(DateTime.utc(2026, 6, 20)), isTrue); // anchor
      expect(s.isOnlineEventWeek(DateTime.utc(2026, 6, 27)), isFalse);
      expect(s.isOnlineEventWeek(DateTime.utc(2026, 7, 4)), isTrue);
      expect(s.isOnlineEventWeek(DateTime.utc(2026, 7, 11)), isFalse);
    });
  });

  group('event reminder firing', () {
    test('sends in-person reminder at Saturday 14:55 (in-person week)',
        () async {
      final sent = <MapEntry<String, String>>[];
      await buildScheduler(sent).tick(inPersonSaturday);

      expect(sent, hasLength(1));
      expect(sent.first.key, equals('!imagineering-portal:imagineering.cc'));
      expect(sent.first.value, contains('318 Russell St'));
      expect(sent.first.value, contains('5 minutes'));
    });

    test('sends online reminder at Saturday 14:55 (online week)', () async {
      final sent = <MapEntry<String, String>>[];
      await buildScheduler(sent).tick(onlineSaturday);

      expect(sent, hasLength(1));
      expect(sent.first.value, contains('world.imagineering.cc'));
      expect(sent.first.value, contains('Imagination Center'));
    });

    test('uses composed message when composeViaAgent is provided', () async {
      final sent = <MapEntry<String, String>>[];
      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (g, m) async => sent.add(MapEntry(g, m)),
        eventReminderRoomId: '!room:imagineering.cc',
        composeViaAgent: (groupId, task) async => 'IN-CHARACTER LINE 🪄',
      );

      await scheduler.tick(inPersonSaturday);

      expect(sent, hasLength(1));
      expect(sent.first.value, equals('IN-CHARACTER LINE 🪄'));
    });

    test('falls back to hardcoded line when composeViaAgent returns empty',
        () async {
      final sent = <MapEntry<String, String>>[];
      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (g, m) async => sent.add(MapEntry(g, m)),
        eventReminderRoomId: '!room:imagineering.cc',
        composeViaAgent: (groupId, task) async => '',
      );

      await scheduler.tick(onlineSaturday);

      expect(sent, hasLength(1));
      expect(sent.first.value, contains('world.imagineering.cc'));
    });
  });

  group('event reminder guards', () {
    test('does not send when no room id is configured', () async {
      final sent = <MapEntry<String, String>>[];
      await buildScheduler(sent, roomId: null).tick(inPersonSaturday);
      expect(sent, isEmpty);
    });

    test('does not send before 14:55', () async {
      final sent = <MapEntry<String, String>>[];
      // 14:54 Melbourne == 04:54 UTC.
      await buildScheduler(sent).tick(DateTime.utc(2026, 6, 27, 4, 54));
      expect(sent, isEmpty);
    });

    test('does not send on a non-Saturday', () async {
      final sent = <MapEntry<String, String>>[];
      // Friday 2026-06-26 14:55 Melbourne == 04:55 UTC.
      await buildScheduler(sent).tick(DateTime.utc(2026, 6, 26, 4, 55));
      expect(sent, isEmpty);
    });

    test('fires at most once per Saturday across multiple ticks', () async {
      final sent = <MapEntry<String, String>>[];
      final scheduler = buildScheduler(sent);

      // Two ticks within the 14:55–15:00 window (e.g. timer drift).
      await scheduler.tick(inPersonSaturday);
      await scheduler.tick(DateTime.utc(2026, 6, 27, 4, 56));

      expect(sent, hasLength(1));
    });

    test('still fires within window if 14:55 tick was missed', () async {
      final sent = <MapEntry<String, String>>[];
      // First tick lands at 14:58 Melbourne == 04:58 UTC.
      await buildScheduler(sent).tick(DateTime.utc(2026, 6, 27, 4, 58));
      expect(sent, hasLength(1));
    });
  });
}
