import 'package:dreamfinder/src/db/database.dart';
import 'package:dreamfinder/src/db/queries.dart';
import 'package:dreamfinder/src/db/schema.dart';
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

  group('DreamQueries', () {
    test('createDreamCycle returns row ID', () {
      final id = queries.createDreamCycle(
        signalGroupId: 'group-1',
        date: '2026-03-14',
        triggeredByUuid: 'user-abc',
      );
      expect(id, greaterThan(0));
    });

    test('getDreamCycle returns matching cycle', () {
      queries.createDreamCycle(
        signalGroupId: 'group-1',
        date: '2026-03-14',
        triggeredByUuid: 'user-abc',
      );

      final cycle = queries.getDreamCycle('group-1', '2026-03-14');
      expect(cycle, isNotNull);
      expect(cycle!.signalGroupId, equals('group-1'));
      expect(cycle.date, equals('2026-03-14'));
      expect(cycle.status, equals(DreamCycleStatus.dreaming));
      expect(cycle.triggeredByUuid, equals('user-abc'));
    });

    test('getDreamCycle returns null for unknown group/date', () {
      expect(queries.getDreamCycle('group-1', '2026-03-14'), isNull);
    });

    test('UNIQUE constraint prevents duplicate group+date', () {
      queries.createDreamCycle(
        signalGroupId: 'group-1',
        date: '2026-03-14',
        triggeredByUuid: 'user-abc',
      );

      expect(
        () => queries.createDreamCycle(
          signalGroupId: 'group-1',
          date: '2026-03-14',
          triggeredByUuid: 'user-def',
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('allows same group on different dates', () {
      final id1 = queries.createDreamCycle(
        signalGroupId: 'group-1',
        date: '2026-03-14',
        triggeredByUuid: 'user-abc',
      );
      final id2 = queries.createDreamCycle(
        signalGroupId: 'group-1',
        date: '2026-03-15',
        triggeredByUuid: 'user-abc',
      );

      expect(id1, isNot(equals(id2)));
    });

    test('updateDreamCycle updates status and completedAt', () {
      final id = queries.createDreamCycle(
        signalGroupId: 'group-1',
        date: '2026-03-14',
        triggeredByUuid: 'user-abc',
      );

      queries.updateDreamCycle(
        id,
        status: DreamCycleStatus.completed,
        completedAt: '2026-03-14T23:30:00',
      );

      final cycle = queries.getDreamCycle('group-1', '2026-03-14');
      expect(cycle!.status, equals(DreamCycleStatus.completed));
      expect(cycle.completedAt, equals('2026-03-14T23:30:00'));
    });

    test('updateDreamCycle records error on failure', () {
      final id = queries.createDreamCycle(
        signalGroupId: 'group-1',
        date: '2026-03-14',
        triggeredByUuid: 'user-abc',
      );

      queries.updateDreamCycle(
        id,
        status: DreamCycleStatus.failed,
        completedAt: '2026-03-14T23:30:00',
        errorMessage: 'MCP server unreachable',
      );

      final cycle = queries.getDreamCycle('group-1', '2026-03-14');
      expect(cycle!.status, equals(DreamCycleStatus.failed));
      expect(cycle.errorMessage, equals('MCP server unreachable'));
    });

    test('getLastCompletedDreamCycle returns most recent completed', () {
      final id1 = queries.createDreamCycle(
        signalGroupId: 'group-1',
        date: '2026-03-12',
        triggeredByUuid: 'user-abc',
      );
      queries.updateDreamCycle(
        id1,
        status: DreamCycleStatus.completed,
        completedAt: '2026-03-12T23:00:00',
      );

      final id2 = queries.createDreamCycle(
        signalGroupId: 'group-1',
        date: '2026-03-13',
        triggeredByUuid: 'user-abc',
      );
      queries.updateDreamCycle(
        id2,
        status: DreamCycleStatus.failed,
        errorMessage: 'Oops',
      );

      final last = queries.getLastCompletedDreamCycle('group-1');
      expect(last, isNotNull);
      expect(last!.date, equals('2026-03-12'));
    });

    test('getLastCompletedDreamCycle returns null when none completed', () {
      queries.createDreamCycle(
        signalGroupId: 'group-1',
        date: '2026-03-14',
        triggeredByUuid: 'user-abc',
      );
      // Still 'dreaming' status — not completed.

      expect(queries.getLastCompletedDreamCycle('group-1'), isNull);
    });

    test('getLastCompletedDreamCycle ignores other groups', () {
      final id = queries.createDreamCycle(
        signalGroupId: 'group-2',
        date: '2026-03-14',
        triggeredByUuid: 'user-abc',
      );
      queries.updateDreamCycle(id, status: DreamCycleStatus.completed);

      expect(queries.getLastCompletedDreamCycle('group-1'), isNull);
    });
  });
}
