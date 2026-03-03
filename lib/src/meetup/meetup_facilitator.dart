/// Orchestrator that wires the meetup session state machine to browser
/// interaction, driving a full build-sprint meetup in Google Meet.
library;

import 'meet_browser.dart';
import 'meetup_config.dart';
import 'meetup_session.dart';
import 'participant_tracker.dart';

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

  /// Per-participant tracker for the intros phase.
  ParticipantTracker? _introTracker;

  /// Per-participant tracker for the demos phase.
  ParticipantTracker? _demoTracker;

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
    await browser.startCaptionScraping();

    session.start(now);
    _started = true;

    await browser.speak(_introAnnouncement());

    // Start per-participant intro tracking if participants are configured.
    if (config.participants.isNotEmpty) {
      _introTracker = ParticipantTracker(
        participants: config.participants,
        perPersonDuration: config.introDuration,
      );
      _introTracker!.startCurrentParticipant(now);
      await browser.speak(_participantPrompt(
        _introTracker!.currentParticipant!,
        isIntro: true,
        isFirst: true,
      ));
    }
  }

  /// Check timing and take any needed actions (warnings, phase transitions).
  ///
  /// Call this periodically (every 1-2 seconds). Does nothing if not started
  /// or if the session is complete.
  Future<void> tick(DateTime now) async {
    if (!isRunning) return;

    // Per-participant tracking for intros and demos.
    if (session.phase == MeetupPhase.intros && _introTracker != null) {
      await _tickParticipantPhase(_introTracker!, now, isIntro: true);
    }
    if (session.phase == MeetupPhase.demos && _demoTracker != null) {
      await _tickParticipantPhase(_demoTracker!, now, isIntro: false);
    }

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

    // Start per-participant demo tracking when entering demos phase.
    if (newPhase == MeetupPhase.demos && config.participants.isNotEmpty) {
      _demoTracker = ParticipantTracker(
        participants: config.participants,
        perPersonDuration: config.demoDuration,
      );
      _demoTracker!.startCurrentParticipant(now);
      await browser.speak(_participantPrompt(
        _demoTracker!.currentParticipant!,
        isIntro: false,
        isFirst: true,
      ));
    }

    // Leave the call when the session is complete.
    if (newPhase == MeetupPhase.done) {
      await browser.leaveMeet();
    }
  }

  /// Handle per-participant timing within intros or demos.
  Future<void> _tickParticipantPhase(
    ParticipantTracker tracker,
    DateTime now, {
    required bool isIntro,
  }) async {
    if (tracker.isComplete) return;

    final result = tracker.check(now);

    switch (result.newTier) {
      case InterruptTier.none:
      case InterruptTier.listenForPause:
        // No-op for now. Future: poll captions for pause detection.
        break;

      case InterruptTier.warningSpoken:
        await browser.speak('15 seconds!');

      case InterruptTier.cutoff:
        await _advanceParticipant(tracker, now, isIntro: isIntro, firm: false);

      case InterruptTier.firmCutoff:
        await _advanceParticipant(tracker, now, isIntro: isIntro, firm: true);
    }
  }

  /// Thank the current participant and prompt the next one (or wrap up).
  Future<void> _advanceParticipant(
    ParticipantTracker tracker,
    DateTime now, {
    required bool isIntro,
    required bool firm,
  }) async {
    final current = tracker.currentParticipant ?? 'participant';
    final next = tracker.nextParticipant;

    if (firm) {
      await browser.speak('We need to move on. Thanks, $current!');
    } else {
      await browser.speak('Thanks, $current!');
    }

    tracker.advance(now);

    if (next != null) {
      await browser.speak(_participantPrompt(next, isIntro: isIntro));
    } else {
      await browser.speak(
        "That's everyone! Great ${isIntro ? 'intros' : 'demos'}.",
      );
    }
  }

  /// Prompt for a participant to start their turn.
  String _participantPrompt(
    String name, {
    required bool isIntro,
    bool isFirst = false,
  }) {
    final prefix = isFirst ? 'First up' : 'Next up';
    if (isIntro) {
      return '$prefix: $name! What are you building today?';
    }
    return "$prefix: $name! Show us what you've built.";
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
