import 'package:dreamfinder/src/db/database.dart';
import 'package:dreamfinder/src/db/queries.dart';
import 'package:dreamfinder/src/session/session_state.dart';
import 'package:test/test.dart';

void main() {
  late BotDatabase db;
  late Queries queries;
  late SessionState state;

  const groupId = 'test-group-id';

  setUp(() {
    db = BotDatabase.inMemory();
    queries = Queries(db);
    state = SessionState(queries: queries);
  });

  tearDown(() => db.close());

  group('SessionPhase', () {
    test('fromNumber returns correct phase for all 8 phases', () {
      expect(SessionPhase.fromNumber(1), SessionPhase.pitch);
      expect(SessionPhase.fromNumber(2), SessionPhase.build1);
      expect(SessionPhase.fromNumber(3), SessionPhase.chat1);
      expect(SessionPhase.fromNumber(4), SessionPhase.build2);
      expect(SessionPhase.fromNumber(5), SessionPhase.chat2);
      expect(SessionPhase.fromNumber(6), SessionPhase.build3);
      expect(SessionPhase.fromNumber(7), SessionPhase.chat3);
      expect(SessionPhase.fromNumber(8), SessionPhase.demo);
    });

    test('fromNumber returns null for out-of-range', () {
      expect(SessionPhase.fromNumber(0), isNull);
      expect(SessionPhase.fromNumber(9), isNull);
      expect(SessionPhase.fromNumber(-1), isNull);
    });

    test('has correct labels', () {
      for (final phase in SessionPhase.values) {
        expect(phase.label, isNotEmpty);
      }
    });
  });

  group('getActiveSession', () {
    test('returns null when no session exists', () {
      expect(state.getActiveSession(groupId), isNull);
    });

    test('returns the current phase after starting', () {
      state.startSession(groupId, initiatorId: 'user-1');
      expect(state.getActiveSession(groupId), SessionPhase.pitch);
    });

    test('returns null after ending', () {
      state.startSession(groupId, initiatorId: 'user-1');
      state.endSession(groupId);
      expect(state.getActiveSession(groupId), isNull);
    });
  });

  group('startSession', () {
    test('starts at pitch phase', () {
      final started = state.startSession(groupId, initiatorId: 'user-1');
      expect(started, isTrue);
      expect(state.getActiveSession(groupId), SessionPhase.pitch);
    });

    test('returns false if session already active', () {
      state.startSession(groupId, initiatorId: 'user-1');
      final startedAgain =
          state.startSession(groupId, initiatorId: 'user-1');
      expect(startedAgain, isFalse);
    });

    test('can restart after ending', () {
      state.startSession(groupId, initiatorId: 'user-1');
      state.endSession(groupId);
      final restarted = state.startSession(groupId, initiatorId: 'user-2');
      expect(restarted, isTrue);
      expect(state.getActiveSession(groupId), SessionPhase.pitch);
    });
  });

  group('advanceSession', () {
    test('advances through all 7 transitions in order', () {
      state.startSession(groupId, initiatorId: 'user-1');

      expect(state.advanceSession(groupId), SessionPhase.build1);
      expect(state.advanceSession(groupId), SessionPhase.chat1);
      expect(state.advanceSession(groupId), SessionPhase.build2);
      expect(state.advanceSession(groupId), SessionPhase.chat2);
      expect(state.advanceSession(groupId), SessionPhase.build3);
      expect(state.advanceSession(groupId), SessionPhase.chat3);
      expect(state.advanceSession(groupId), SessionPhase.demo);
    });

    test('returns null when on the final phase', () {
      state.startSession(groupId, initiatorId: 'user-1');
      // Advance all 7 times to reach demo.
      for (var i = 0; i < 7; i++) {
        state.advanceSession(groupId);
      }

      expect(state.advanceSession(groupId), isNull);
      // Still on demo.
      expect(state.getActiveSession(groupId), SessionPhase.demo);
    });

    test('returns null when no session is active', () {
      expect(state.advanceSession(groupId), isNull);
    });
  });

  group('endSession', () {
    test('clears session state', () {
      state.startSession(groupId, initiatorId: 'user-1');
      state.endSession(groupId);
      expect(state.getActiveSession(groupId), isNull);
    });
  });

  group('participants', () {
    test('initiator is added automatically', () {
      state.startSession(groupId, initiatorId: 'user-1');
      final participants = state.getParticipants(groupId);
      expect(participants, contains('user-1'));
    });

    test('addParticipant stores a participant', () {
      state.startSession(groupId, initiatorId: 'user-1');
      final added = state.addParticipant(groupId, 'user-2');
      expect(added, isTrue);
      final participants = state.getParticipants(groupId);
      expect(participants, contains('user-2'));
    });

    test('addParticipant returns false for duplicates', () {
      state.startSession(groupId, initiatorId: 'user-1');
      final added = state.addParticipant(groupId, 'user-1');
      expect(added, isFalse);
    });

    test('getParticipants returns empty list when no session', () {
      expect(state.getParticipants(groupId), isEmpty);
    });

    test('getParticipants returns all added participants', () {
      state.startSession(groupId, initiatorId: 'user-1');
      state.addParticipant(groupId, 'user-2');
      state.addParticipant(groupId, 'user-3');
      final participants = state.getParticipants(groupId);
      expect(participants, hasLength(3)); // initiator + 2 added
    });

    test('endSession clears participants', () {
      state.startSession(groupId, initiatorId: 'user-1');
      state.addParticipant(groupId, 'user-2');
      state.endSession(groupId);
      expect(state.getParticipants(groupId), isEmpty);
    });
  });

  group('per-group isolation', () {
    test('different groups have independent sessions', () {
      const groupA = 'group-a';
      const groupB = 'group-b';

      state.startSession(groupA, initiatorId: 'user-a');
      expect(state.getActiveSession(groupA), SessionPhase.pitch);
      expect(state.getActiveSession(groupB), isNull);

      state.startSession(groupB, initiatorId: 'user-b');
      state.advanceSession(groupB);

      expect(state.getActiveSession(groupA), SessionPhase.pitch);
      expect(state.getActiveSession(groupB), SessionPhase.build1);
    });
  });
}
