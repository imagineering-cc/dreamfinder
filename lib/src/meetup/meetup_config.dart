/// Configuration for a structured build-sprint meetup.
library;

/// Defines the Meet link, participant list, and timing for each phase.
///
/// Durations default to the standard 2-hour format:
/// intros (5 min) -> 3 x (25 min sprint + 10 min break) -> demos (5 min).
class MeetupConfig {
  const MeetupConfig({
    required this.meetLink,
    this.participants = const [],
    this.displayName = 'Dreamfinder',
    this.introDuration = const Duration(seconds: 60),
    this.sprintDuration = const Duration(minutes: 25),
    this.breakDuration = const Duration(minutes: 10),
    this.demoDuration = const Duration(seconds: 60),
    this.sprintCount = 3,
    this.introTotalDuration = const Duration(minutes: 5),
    this.demoTotalDuration = const Duration(minutes: 5),
  });

  /// Google Meet URL to join.
  final String meetLink;

  /// Ordered list of participant names for intros and demos.
  final List<String> participants;

  /// Display name for Dreamfinder in the Meet call.
  final String displayName;

  /// Per-person intro time limit.
  final Duration introDuration;

  /// Duration of each build sprint.
  final Duration sprintDuration;

  /// Duration of each break between sprints.
  final Duration breakDuration;

  /// Per-person demo time limit.
  final Duration demoDuration;

  /// Number of build sprints (default: 3).
  final int sprintCount;

  /// Total time for the intro round.
  final Duration introTotalDuration;

  /// Total time for the demo round.
  final Duration demoTotalDuration;
}
