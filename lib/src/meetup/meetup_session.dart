/// State machine for meetup phase transitions.
library;

import 'meetup_config.dart';

/// Phases of a structured build-sprint meetup.
///
/// The session progresses linearly:
/// ```
/// idle -> intros -> sprint1 -> break1 -> sprint2 -> break2
///      -> sprint3 -> break3 -> demos -> done
/// ```
enum MeetupPhase {
  idle,
  intros,
  sprint1,
  break1,
  sprint2,
  break2,
  sprint3,
  break3,
  demos,
  done;

  /// Whether this phase is a build sprint.
  bool get isSprint => switch (this) {
        sprint1 || sprint2 || sprint3 => true,
        _ => false,
      };

  /// Whether this phase is a break.
  bool get isBreak => switch (this) {
        break1 || break2 || break3 => true,
        _ => false,
      };

  /// Whether this is an active phase (not idle or done).
  bool get isActive => this != idle && this != done;

  /// The next phase in sequence, or `null` if the session is complete.
  MeetupPhase? get next {
    final idx = index + 1;
    if (idx >= values.length) return null;
    return values[idx];
  }
}

/// Tracks the current state of a meetup session.
///
/// Manages phase transitions and timing. The session starts in
/// [MeetupPhase.idle] and advances linearly through each phase until
/// [MeetupPhase.done].
class MeetupSession {
  MeetupSession({required this.config});

  /// Configuration for this session.
  final MeetupConfig config;

  MeetupPhase _phase = MeetupPhase.idle;
  DateTime? _phaseStartedAt;

  /// Current phase of the meetup.
  MeetupPhase get phase => _phase;

  /// When the current phase started, or `null` if idle.
  DateTime? get phaseStartedAt => _phaseStartedAt;

  /// Duration allocated for the given [phase].
  Duration phaseDuration(MeetupPhase phase) => switch (phase) {
        MeetupPhase.idle || MeetupPhase.done => Duration.zero,
        MeetupPhase.intros => config.introTotalDuration,
        MeetupPhase.sprint1 ||
        MeetupPhase.sprint2 ||
        MeetupPhase.sprint3 =>
          config.sprintDuration,
        MeetupPhase.break1 ||
        MeetupPhase.break2 ||
        MeetupPhase.break3 =>
          config.breakDuration,
        MeetupPhase.demos => config.demoTotalDuration,
      };

  /// Duration of the current phase.
  Duration get currentPhaseDuration => phaseDuration(_phase);

  /// Time elapsed in the current phase.
  Duration elapsed(DateTime now) {
    if (_phaseStartedAt == null) return Duration.zero;
    return now.difference(_phaseStartedAt!);
  }

  /// Time remaining in the current phase.
  Duration remaining(DateTime now) {
    final left = currentPhaseDuration - elapsed(now);
    return left.isNegative ? Duration.zero : left;
  }

  /// Whether the current phase's time has expired.
  bool isPhaseExpired(DateTime now) =>
      _phase.isActive && remaining(now) == Duration.zero;

  /// Start the session, transitioning from idle to intros.
  ///
  /// Throws [StateError] if the session has already started.
  void start(DateTime now) {
    if (_phase != MeetupPhase.idle) {
      throw StateError('Session already started (current phase: $_phase)');
    }
    _phase = MeetupPhase.intros;
    _phaseStartedAt = now;
  }

  /// Advance to the next phase.
  ///
  /// Returns the new [MeetupPhase]. Throws [StateError] if the session
  /// is idle (not started) or already complete.
  MeetupPhase advance(DateTime now) {
    if (_phase == MeetupPhase.idle) {
      throw StateError('Session not started — call start() first');
    }
    final next = _phase.next;
    if (next == null) {
      throw StateError('Session is already complete');
    }
    _phase = next;
    _phaseStartedAt = now;
    return _phase;
  }
}
