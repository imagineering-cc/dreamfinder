/// Orchestrator that wires the meetup session state machine to browser
/// interaction, driving a full build-sprint meetup in Google Meet.
library;

import 'meet_browser.dart';
import 'meetup_config.dart';
import 'meetup_session.dart';

/// Facilitates a structured build-sprint meetup in Google Meet.
///
/// Joins the call, announces phases, sends time warnings during sprints,
/// and transitions through the full session. Call [tick] periodically
/// (e.g. every second) to drive timing.
///
/// ```
/// final facilitator = MeetupFacilitator(browser: browser, config: config);
/// await facilitator.start(DateTime.now());
/// // In a timer loop:
/// await facilitator.tick(DateTime.now());
/// ```
class MeetupFacilitator {
  MeetupFacilitator({
    required this.browser,
    required this.config,
  }) : session = MeetupSession(config: config);

  /// Browser interface for Google Meet interaction.
  final MeetBrowser browser;

  /// Configuration for this meetup.
  final MeetupConfig config;

  /// Session state machine tracking phase and timing.
  final MeetupSession session;

  bool _started = false;
  bool _fiveMinWarned = false;
  bool _oneMinWarned = false;

  /// Whether the facilitator is actively running (started and not done).
  bool get isRunning => _started && session.phase.isActive;

  /// Current meetup phase.
  MeetupPhase get phase => session.phase;

  /// Start the meetup: join the Meet call, enable captions, and announce.
  ///
  /// Throws [StateError] if already started.
  Future<void> start(DateTime now) async {
    if (_started) {
      throw StateError('Facilitator already started');
    }

    await browser.joinMeet(
      meetLink: config.meetLink,
      displayName: config.displayName,
    );
    await browser.enableCaptions();

    session.start(now);
    _started = true;

    await browser.speak(_introAnnouncement());
  }

  /// Check timing and take any needed actions (warnings, phase transitions).
  ///
  /// Call this periodically (every 1-2 seconds). Does nothing if not started
  /// or if the session is complete.
  Future<void> tick(DateTime now) async {
    if (!isRunning) return;

    final remaining = session.remaining(now);

    // Sprint time warnings — checked before expiry so warnings fire
    // before the phase transition announcement.
    if (session.phase.isSprint) {
      if (!_fiveMinWarned &&
          remaining <= const Duration(minutes: 5) &&
          remaining > Duration.zero &&
          session.currentPhaseDuration > const Duration(minutes: 5)) {
        _fiveMinWarned = true;
        await browser.speak('Five minutes left in this sprint!');
      }
      if (!_oneMinWarned &&
          remaining <= const Duration(minutes: 1) &&
          remaining > Duration.zero &&
          session.currentPhaseDuration > const Duration(minutes: 1)) {
        _oneMinWarned = true;
        await browser.speak('One minute! Start wrapping up.');
      }
    }

    // Phase expired — advance to the next one.
    if (session.isPhaseExpired(now)) {
      await _advancePhase(now);
    }
  }

  /// Stop the meetup early with a goodbye message.
  ///
  /// Does nothing if not started or already complete.
  Future<void> stop(DateTime now) async {
    if (!_started || session.phase == MeetupPhase.done) return;

    await browser.speak(
      "That's a wrap! Thanks everyone for a great session.",
    );
    await browser.leaveMeet();

    // Fast-forward the session to done.
    while (session.phase != MeetupPhase.done) {
      session.advance(now);
    }
  }

  /// Advance to the next phase, reset warning flags, and announce.
  Future<void> _advancePhase(DateTime now) async {
    final newPhase = session.advance(now);
    _fiveMinWarned = false;
    _oneMinWarned = false;

    final announcement = _phaseAnnouncement(newPhase);
    if (announcement != null) {
      await browser.speak(announcement);
    }

    // Leave the call when the session is complete.
    if (newPhase == MeetupPhase.done) {
      await browser.leaveMeet();
    }
  }

  /// Opening announcement when the facilitator joins.
  String _introAnnouncement() {
    final names = config.participants;
    if (names.isEmpty) {
      return "Hello everyone! I'm ${config.displayName}, your facilitator "
          "today. Let's get started with quick intros — one minute each!";
    }
    return "Hello everyone! I'm ${config.displayName}, your facilitator "
        "today. We've got ${names.length} builders here. "
        "Let's get started with quick intros — one minute each!";
  }

  /// Announcement for entering a new phase. Returns `null` for phases
  /// that don't need an announcement (idle, intros — handled by [start]).
  String? _phaseAnnouncement(MeetupPhase phase) {
    final sprintMins = config.sprintDuration.inMinutes;
    final breakMins = config.breakDuration.inMinutes;

    return switch (phase) {
      MeetupPhase.sprint1 =>
        "Alright, Sprint 1 begins now! You've got $sprintMins minutes. "
            'Go build something awesome!',
      MeetupPhase.break1 =>
        'Time! Great sprint everyone. $breakMins-minute break '
            '— share what you built, ask questions!',
      MeetupPhase.sprint2 =>
        "Sprint 2, let's go! Another $sprintMins minutes on the clock.",
      MeetupPhase.break2 =>
        "And that's Sprint 2! Take $breakMins, share your progress.",
      MeetupPhase.sprint3 =>
        'Final sprint! Sprint 3, $sprintMins minutes. Make it count!',
      MeetupPhase.break3 =>
        'Sprint 3 complete! Last break before demos. $breakMins minutes.',
      MeetupPhase.demos =>
        "Demo time! Let's see what everyone built. One minute each.",
      MeetupPhase.done =>
        "That's a wrap! Amazing work today, imagineers. See you next time!",
      MeetupPhase.idle || MeetupPhase.intros => null,
    };
  }
}
