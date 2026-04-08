import 'dart:async';

import 'package:dreamfinder/src/db/database.dart';
import 'package:dreamfinder/src/db/queries.dart';
import 'package:dreamfinder/src/session/session_state.dart';
import 'package:dreamfinder/src/session/session_timer.dart';
import 'package:test/test.dart';

void main() {
  late BotDatabase db;
  late Queries queries;
  late SessionState state;

  const groupId = 'test-group';

  setUp(() {
    db = BotDatabase.inMemory();
    queries = Queries(db);
    state = SessionState(queries: queries);
  });

  tearDown(() => db.close());

  group('phaseDuration', () {
    test('pitch is 10 minutes', () {
      expect(
        SessionTimer.phaseDuration(SessionPhase.pitch),
        const Duration(minutes: 10),
      );
    });

    test('all build phases are 25 minutes', () {
      for (final phase in [
        SessionPhase.build1,
        SessionPhase.build2,
        SessionPhase.build3,
      ]) {
        expect(
          SessionTimer.phaseDuration(phase),
          const Duration(minutes: 25),
          reason: '${phase.label} should be 25 minutes',
        );
      }
    });

    test('all chat phases are 5 minutes', () {
      for (final phase in [
        SessionPhase.chat1,
        SessionPhase.chat2,
        SessionPhase.chat3,
      ]) {
        expect(
          SessionTimer.phaseDuration(phase),
          const Duration(minutes: 5),
          reason: '${phase.label} should be 5 minutes',
        );
      }
    });

    test('demo has no duration (open-ended)', () {
      expect(SessionTimer.phaseDuration(SessionPhase.demo), isNull);
    });
  });

  group('startTimer', () {
    test('creates a timer for the given phase', () {
      final durations = <Duration>[];
      final timer = SessionTimer(
        sessionState: state,
        onPhaseTransition: (_, __) async {},
        timerFactory: (duration, callback) {
          durations.add(duration);
          return _NoopTimer();
        },
      );

      state.startSession(groupId, initiatorId: 'user-1');
      timer.startTimer(groupId, SessionPhase.pitch);

      expect(durations, [const Duration(minutes: 10)]);
      expect(timer.hasTimer(groupId), isTrue);
    });

    test('does nothing for demo phase (no duration)', () {
      var timerCreated = false;
      final timer = SessionTimer(
        sessionState: state,
        onPhaseTransition: (_, __) async {},
        timerFactory: (duration, callback) {
          timerCreated = true;
          return _NoopTimer();
        },
      );

      timer.startTimer(groupId, SessionPhase.demo);

      expect(timerCreated, isFalse);
      expect(timer.hasTimer(groupId), isFalse);
    });

    test('cancels existing timer before starting new one', () {
      var cancelCount = 0;
      final timer = SessionTimer(
        sessionState: state,
        onPhaseTransition: (_, __) async {},
        timerFactory: (duration, callback) => _TrackingTimer(
          onCancel: () => cancelCount++,
        ),
      );

      state.startSession(groupId, initiatorId: 'user-1');
      timer.startTimer(groupId, SessionPhase.pitch);
      timer.startTimer(groupId, SessionPhase.build1);

      expect(cancelCount, 1);
    });
  });

  group('cancelTimer', () {
    test('cancels the active timer', () {
      var cancelled = false;
      final timer = SessionTimer(
        sessionState: state,
        onPhaseTransition: (_, __) async {},
        timerFactory: (duration, callback) => _TrackingTimer(
          onCancel: () => cancelled = true,
        ),
      );

      state.startSession(groupId, initiatorId: 'user-1');
      timer.startTimer(groupId, SessionPhase.pitch);
      timer.cancelTimer(groupId);

      expect(cancelled, isTrue);
      expect(timer.hasTimer(groupId), isFalse);
    });

    test('is a no-op for non-existent group', () {
      final timer = SessionTimer(
        sessionState: state,
        onPhaseTransition: (_, __) async {},
      );

      // Should not throw.
      timer.cancelTimer('non-existent');
    });
  });

  group('auto-advance on timer fire', () {
    test('advances session and notifies on timer fire', () async {
      void Function()? fireTimer;
      final transitions = <(String, SessionPhase)>[];

      final timer = SessionTimer(
        sessionState: state,
        onPhaseTransition: (groupId, phase) async {
          transitions.add((groupId, phase));
        },
        timerFactory: (duration, callback) {
          fireTimer = callback;
          return _NoopTimer();
        },
      );

      state.startSession(groupId, initiatorId: 'user-1');
      timer.startTimer(groupId, SessionPhase.pitch);

      // Simulate timer firing.
      fireTimer!();

      expect(transitions, hasLength(1));
      expect(transitions.first.$1, groupId);
      expect(transitions.first.$2, SessionPhase.build1);
      expect(state.getActiveSession(groupId), SessionPhase.build1);
    });

    test('chains timers through all phases', () {
      final callbacks = <void Function()>[];
      final transitions = <SessionPhase>[];

      final timer = SessionTimer(
        sessionState: state,
        onPhaseTransition: (_, phase) async {
          transitions.add(phase);
        },
        timerFactory: (duration, callback) {
          callbacks.add(callback);
          return _NoopTimer();
        },
      );

      state.startSession(groupId, initiatorId: 'user-1');
      timer.startTimer(groupId, SessionPhase.pitch);

      // Fire each timer to chain through all phases.
      // pitch→build1→chat1→build2→chat2→build3→chat3→demo
      for (var i = 0; i < 7; i++) {
        callbacks[i]();
      }

      expect(transitions, [
        SessionPhase.build1,
        SessionPhase.chat1,
        SessionPhase.build2,
        SessionPhase.chat2,
        SessionPhase.build3,
        SessionPhase.chat3,
        SessionPhase.demo,
      ]);

      // No timer for demo (open-ended).
      expect(callbacks, hasLength(7));
      expect(timer.hasTimer(groupId), isFalse);
    });

    test('does not advance if session was ended externally', () {
      void Function()? fireTimer;
      final transitions = <SessionPhase>[];

      final timer = SessionTimer(
        sessionState: state,
        onPhaseTransition: (_, phase) async {
          transitions.add(phase);
        },
        timerFactory: (duration, callback) {
          fireTimer = callback;
          return _NoopTimer();
        },
      );

      state.startSession(groupId, initiatorId: 'user-1');
      timer.startTimer(groupId, SessionPhase.pitch);

      // End session before timer fires.
      state.endSession(groupId);
      fireTimer!();

      expect(transitions, isEmpty);
    });
  });

  group('per-group isolation', () {
    test('timers for different groups are independent', () {
      final firedGroups = <String>[];
      final callbacks = <String, void Function()>{};
      void Function() lastCallback = () {};

      final timer = SessionTimer(
        sessionState: state,
        onPhaseTransition: (groupId, _) async {
          firedGroups.add(groupId);
        },
        timerFactory: (duration, callback) {
          lastCallback = callback;
          return _NoopTimer();
        },
      );

      const groupA = 'group-a';
      const groupB = 'group-b';

      state.startSession(groupA, initiatorId: 'user-a');
      state.startSession(groupB, initiatorId: 'user-b');

      timer.startTimer(groupA, SessionPhase.pitch);
      callbacks['a'] = lastCallback;

      timer.startTimer(groupB, SessionPhase.pitch);
      callbacks['b'] = lastCallback;

      // Fire only group A — group B should be unaffected.
      callbacks['a']!();

      expect(firedGroups, ['group-a']);
      expect(state.getActiveSession(groupA), SessionPhase.build1); // advanced
      expect(state.getActiveSession(groupB), SessionPhase.pitch); // unchanged
    });
  });

  group('dispose', () {
    test('cancels all active timers', () {
      var cancelCount = 0;
      final timer = SessionTimer(
        sessionState: state,
        onPhaseTransition: (_, __) async {},
        timerFactory: (duration, callback) => _TrackingTimer(
          onCancel: () => cancelCount++,
        ),
      );

      state.startSession('group-1', initiatorId: 'user-1');
      state.startSession('group-2', initiatorId: 'user-2');
      timer.startTimer('group-1', SessionPhase.build1);
      timer.startTimer('group-2', SessionPhase.chat1);

      timer.dispose();

      expect(cancelCount, 2);
      expect(timer.hasTimer('group-1'), isFalse);
      expect(timer.hasTimer('group-2'), isFalse);
    });
  });
}

/// A timer that does nothing — used when we manually invoke the callback.
class _NoopTimer implements Timer {
  @override
  void cancel() {}

  @override
  bool get isActive => false;

  @override
  int get tick => 0;
}

/// A timer that tracks cancellation.
class _TrackingTimer implements Timer {
  _TrackingTimer({required this.onCancel});

  final void Function() onCancel;
  bool _active = true;

  @override
  void cancel() {
    _active = false;
    onCancel();
  }

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}

/// A timer that stores its callback for later invocation.
class _CallbackTimer implements Timer {
  _CallbackTimer(this.callback);

  final void Function() callback;
  bool _active = true;

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}
