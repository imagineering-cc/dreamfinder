/// Per-participant time tracking with tiered interrupt escalation.
library;

/// Interrupt severity tiers, escalating as a participant exceeds their time.
///
/// Thresholds are proportional to the per-person duration:
/// - 75% → [listenForPause] (future: detect natural pauses via captions)
/// - 92% → [warningSpoken] (speak a time warning)
/// - 100% → [cutoff] (thank and move to next)
/// - 117% → [firmCutoff] (firmer cutoff, force advance)
enum InterruptTier {
  /// Under 75% — no action needed.
  none,

  /// 75%+ — start listening for a natural pause in speech.
  listenForPause,

  /// 92%+ — speak a time warning ("15 seconds!").
  warningSpoken,

  /// 100%+ — time's up, thank the speaker and advance.
  cutoff,

  /// 117%+ — firm cutoff for over-runners.
  firmCutoff;
}

/// Result of a [ParticipantTracker.check] call.
///
/// [newTier] is the tier that was *just* entered (or [InterruptTier.none] if
/// no new tier was reached since the last check). [shouldAdvance] indicates
/// whether the facilitator should advance to the next participant.
class ParticipantCheckResult {
  const ParticipantCheckResult({
    required this.newTier,
    required this.participant,
    required this.shouldAdvance,
  });

  /// The interrupt tier that was newly reached, or [InterruptTier.none].
  final InterruptTier newTier;

  /// Name of the participant being checked.
  final String participant;

  /// Whether the facilitator should advance to the next participant.
  final bool shouldAdvance;
}

/// Tracks per-participant timing through a list of participants.
///
/// Each participant gets [perPersonDuration]. The tracker reports escalating
/// [InterruptTier]s as time progresses, each tier reported exactly once.
///
/// Usage:
/// ```dart
/// final tracker = ParticipantTracker(
///   participants: ['Alice', 'Bob'],
///   perPersonDuration: Duration(seconds: 60),
/// );
/// tracker.startCurrentParticipant(now);
/// // In a tick loop:
/// final result = tracker.check(now);
/// if (result.newTier == InterruptTier.cutoff) {
///   tracker.advance(now);
/// }
/// ```
class ParticipantTracker {
  ParticipantTracker({
    required this.participants,
    required this.perPersonDuration,
  });

  /// Ordered list of participant names.
  final List<String> participants;

  /// Time allocated to each participant.
  final Duration perPersonDuration;

  int _index = 0;
  DateTime? _startedAt;
  InterruptTier _reportedTier = InterruptTier.none;

  /// Current participant name, or `null` if [isComplete].
  String? get currentParticipant => isComplete ? null : participants[_index];

  /// Next participant name, or `null` if current is the last.
  String? get nextParticipant {
    final next = _index + 1;
    if (next >= participants.length) return null;
    return participants[next];
  }

  /// Whether all participants have been processed.
  bool get isComplete => _index >= participants.length;

  /// Start timing for the current participant.
  void startCurrentParticipant(DateTime now) {
    _startedAt = now;
    _reportedTier = InterruptTier.none;
  }

  /// Time elapsed since the current participant started.
  Duration elapsed(DateTime now) {
    if (_startedAt == null) return Duration.zero;
    return now.difference(_startedAt!);
  }

  /// Check the current participant's time and return any newly-reached tier.
  ///
  /// Each tier is reported exactly once. Subsequent checks in the same tier
  /// return [InterruptTier.none].
  ParticipantCheckResult check(DateTime now) {
    final participant = currentParticipant ?? '';
    if (_startedAt == null || isComplete) {
      return ParticipantCheckResult(
        newTier: InterruptTier.none,
        participant: participant,
        shouldAdvance: false,
      );
    }

    final elapsedMs = elapsed(now).inMilliseconds;
    final totalMs = perPersonDuration.inMilliseconds;

    // Compute the current tier from elapsed ratio.
    final InterruptTier currentTier;
    if (totalMs > 0 && elapsedMs >= (totalMs * 1.17).round()) {
      currentTier = InterruptTier.firmCutoff;
    } else if (totalMs > 0 && elapsedMs >= totalMs) {
      currentTier = InterruptTier.cutoff;
    } else if (totalMs > 0 && elapsedMs >= (totalMs * 0.92).round()) {
      currentTier = InterruptTier.warningSpoken;
    } else if (totalMs > 0 && elapsedMs >= (totalMs * 0.75).round()) {
      currentTier = InterruptTier.listenForPause;
    } else {
      currentTier = InterruptTier.none;
    }

    // Only report a tier if it's higher than what we've already reported.
    if (currentTier.index > _reportedTier.index) {
      _reportedTier = currentTier;
      return ParticipantCheckResult(
        newTier: currentTier,
        participant: participant,
        shouldAdvance: currentTier == InterruptTier.cutoff ||
            currentTier == InterruptTier.firmCutoff,
      );
    }

    return ParticipantCheckResult(
      newTier: InterruptTier.none,
      participant: participant,
      shouldAdvance: false,
    );
  }

  /// Advance to the next participant and start their timer.
  ///
  /// Resets the interrupt tier. Does nothing if already complete.
  void advance(DateTime now) {
    _index++;
    if (!isComplete) {
      startCurrentParticipant(now);
    }
  }
}
