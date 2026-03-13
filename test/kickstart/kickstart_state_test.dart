import 'package:dreamfinder/src/db/database.dart';
import 'package:dreamfinder/src/db/queries.dart';
import 'package:dreamfinder/src/kickstart/kickstart_state.dart';
import 'package:test/test.dart';

void main() {
  late BotDatabase db;
  late Queries queries;
  late KickstartState state;

  const groupId = 'test-group-id';

  setUp(() {
    db = BotDatabase.inMemory();
    queries = Queries(db);
    state = KickstartState(queries: queries);
  });

  tearDown(() => db.close());

  group('KickstartStep', () {
    test('fromNumber returns correct step', () {
      expect(KickstartStep.fromNumber(1), KickstartStep.workspace);
      expect(KickstartStep.fromNumber(2), KickstartStep.roster);
      expect(KickstartStep.fromNumber(3), KickstartStep.projects);
      expect(KickstartStep.fromNumber(4), KickstartStep.knowledge);
      expect(KickstartStep.fromNumber(5), KickstartStep.primer);
    });

    test('fromNumber returns null for out-of-range', () {
      expect(KickstartStep.fromNumber(0), isNull);
      expect(KickstartStep.fromNumber(6), isNull);
      expect(KickstartStep.fromNumber(-1), isNull);
    });

    test('has correct labels', () {
      expect(KickstartStep.workspace.label, 'Workspace Setup');
      expect(KickstartStep.roster.label, 'Team Roster');
      expect(KickstartStep.projects.label, 'Project Seeding');
      expect(KickstartStep.knowledge.label, 'Knowledge Dump');
      expect(KickstartStep.primer.label, 'Dream Primer');
    });
  });

  group('getActiveKickstart', () {
    test('returns null when no kickstart exists', () {
      expect(state.getActiveKickstart(groupId), isNull);
    });

    test('returns the current step after starting', () {
      state.startKickstart(groupId);
      expect(state.getActiveKickstart(groupId), KickstartStep.workspace);
    });

    test('returns null after completing', () {
      state.startKickstart(groupId);
      state.completeKickstart(groupId);
      expect(state.getActiveKickstart(groupId), isNull);
    });
  });

  group('isKickstartActive', () {
    test('returns false when no kickstart exists', () {
      expect(state.isKickstartActive(groupId), isFalse);
    });

    test('returns true when kickstart is active', () {
      state.startKickstart(groupId);
      expect(state.isKickstartActive(groupId), isTrue);
    });

    test('returns false after completing', () {
      state.startKickstart(groupId);
      state.completeKickstart(groupId);
      expect(state.isKickstartActive(groupId), isFalse);
    });
  });

  group('startKickstart', () {
    test('starts at step 1', () {
      final started = state.startKickstart(groupId);
      expect(started, isTrue);
      expect(state.getActiveKickstart(groupId), KickstartStep.workspace);
    });

    test('returns false if already active', () {
      state.startKickstart(groupId);
      final startedAgain = state.startKickstart(groupId);
      expect(startedAgain, isFalse);
    });

    test('can restart after completing', () {
      state.startKickstart(groupId);
      state.completeKickstart(groupId);
      final restarted = state.startKickstart(groupId);
      expect(restarted, isTrue);
      expect(state.getActiveKickstart(groupId), KickstartStep.workspace);
    });
  });

  group('advanceKickstart', () {
    test('advances from workspace to roster', () {
      state.startKickstart(groupId);
      final next = state.advanceKickstart(groupId);
      expect(next, KickstartStep.roster);
      expect(state.getActiveKickstart(groupId), KickstartStep.roster);
    });

    test('advances through all steps', () {
      state.startKickstart(groupId);

      expect(state.advanceKickstart(groupId), KickstartStep.roster);
      expect(state.advanceKickstart(groupId), KickstartStep.projects);
      expect(state.advanceKickstart(groupId), KickstartStep.knowledge);
      expect(state.advanceKickstart(groupId), KickstartStep.primer);
    });

    test('returns null when on the final step', () {
      state.startKickstart(groupId);
      state.advanceKickstart(groupId); // → roster
      state.advanceKickstart(groupId); // → projects
      state.advanceKickstart(groupId); // → knowledge
      state.advanceKickstart(groupId); // → primer

      expect(state.advanceKickstart(groupId), isNull);
      // Still on primer.
      expect(state.getActiveKickstart(groupId), KickstartStep.primer);
    });

    test('returns null when no kickstart is active', () {
      expect(state.advanceKickstart(groupId), isNull);
    });
  });

  group('completeKickstart', () {
    test('marks the kickstart as done', () {
      state.startKickstart(groupId);
      state.completeKickstart(groupId);
      expect(state.isKickstartActive(groupId), isFalse);
      expect(state.getActiveKickstart(groupId), isNull);
    });
  });

  group('per-group isolation', () {
    test('different groups have independent state', () {
      const groupA = 'group-a';
      const groupB = 'group-b';

      state.startKickstart(groupA);
      expect(state.isKickstartActive(groupA), isTrue);
      expect(state.isKickstartActive(groupB), isFalse);

      state.startKickstart(groupB);
      state.advanceKickstart(groupB);

      expect(state.getActiveKickstart(groupA), KickstartStep.workspace);
      expect(state.getActiveKickstart(groupB), KickstartStep.roster);
    });
  });
}
