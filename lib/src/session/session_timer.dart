/// Session phase timer — drives automatic phase transitions.
///
/// When a session phase starts, [SessionTimer] schedules a callback for
/// when the phase's duration elapses. The callback advances the session
/// and starts the timer for the next phase, creating an autonomous
/// facilitation loop.
///
/// This is what turns Dreamfinder from a passive state machine into an
/// active session host — the ability to say "time's up!" without being
/// prompted.
library;

import 'dart:async';

import 'package:meta/meta.dart';

import 'session_state.dart';

/// Callback invoked when a phase timer fires and the session advances.
///
/// The [groupId] identifies which group's session transitioned, and
/// [newPhase] is the phase that was just entered.
typedef PhaseTransitionCallback = Future<void> Function(
  String groupId,
  SessionPhase newPhase,
);

/// Manages per-group phase timers for co-working sessions.
///
/// Each group can have at most one active timer. Starting a new timer
/// cancels any existing one for that group. When the timer fires, it
/// advances the session state and recursively starts the timer for the
/// next phase — creating a chain that drives the session from pitch
/// through demo without human intervention.
class SessionTimer {
  /// Creates a [SessionTimer] that advances sessions via [sessionState]
  /// and notifies via [onPhaseTransition] when phases change.
  ///
  /// The optional [timerFactory] allows injecting a custom timer creator
  /// for testing.
  SessionTimer({
    required this.sessionState,
    required this.onPhaseTransition,
    @visibleForTesting Timer Function(Duration, void Function())? timerFactory,
  }) : _timerFactory = timerFactory ?? Timer.new;

  /// The session state manager used to advance phases.
  final SessionState sessionState;

  /// Called when a phase timer fires and the session transitions.
  final PhaseTransitionCallback onPhaseTransition;

  /// Factory for creating timers — injectable for testing.
  final Timer Function(Duration, void Function()) _timerFactory;

  /// Active timers keyed by group ID.
  final Map<String, Timer> _timers = {};

  /// Starts (or restarts) the phase timer for [groupId].
  ///
  /// Cancels any existing timer for this group, then schedules a new one
  /// based on [phase]'s duration. When the timer fires:
  /// 1. Advances the session to the next phase
  /// 2. Notifies via [onPhaseTransition]
  /// 3. Starts the timer for the new phase (auto-chain)
  ///
  /// Does nothing if [phase] has no duration (e.g. demo).
  void startTimer(String groupId, SessionPhase phase) {
    cancelTimer(groupId);
    final duration = phaseDuration(phase);
    if (duration == null) return;

    _timers[groupId] = _timerFactory(duration, () {
      _onTimerFired(groupId);
    });
  }

  /// Cancels the active timer for [groupId], if any.
  void cancelTimer(String groupId) {
    _timers[groupId]?.cancel();
    _timers.remove(groupId);
  }

  /// Returns `true` if [groupId] has an active timer.
  bool hasTimer(String groupId) => _timers.containsKey(groupId);

  /// Cancels all active timers. Call on shutdown.
  void dispose() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
  }

  /// Returns the duration for a given [phase].
  ///
  /// - Pitch: 10 minutes (generous for introductions)
  /// - Build phases: 25 minutes (focused work)
  /// - Chat phases: 5 minutes (check-in breaks)
  /// - Demo: no timer (ends when the host wraps up)
  static Duration? phaseDuration(SessionPhase phase) => switch (phase) {
        SessionPhase.pitch => const Duration(minutes: 10),
        SessionPhase.build1 ||
        SessionPhase.build2 ||
        SessionPhase.build3 => const Duration(minutes: 25),
        SessionPhase.chat1 ||
        SessionPhase.chat2 ||
        SessionPhase.chat3 => const Duration(minutes: 5),
        SessionPhase.demo => null,
      };

  /// Handles a timer firing: advance state, notify, chain next timer.
  void _onTimerFired(String groupId) {
    _timers.remove(groupId);
    final nextPhase = sessionState.advanceSession(groupId);
    if (nextPhase == null) return;

    // Notify the host to compose and send a transition message.
    onPhaseTransition(groupId, nextPhase);

    // Chain: start the timer for the new phase.
    startTimer(groupId, nextPhase);
  }
}
