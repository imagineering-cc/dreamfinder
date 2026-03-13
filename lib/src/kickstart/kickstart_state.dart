/// Kickstart state management — persists guided onboarding progress per group.
///
/// Uses the `bot_metadata` key-value table (via [MetadataQueries]) to track
/// which step of the kickstart flow each group is on. Keys follow the pattern
/// `kickstart::<groupId>` with a JSON value containing the step number and
/// timestamp.
library;

import 'dart:convert';

import '../db/queries.dart';

/// The five steps of the kickstart guided onboarding flow.
///
/// Each step focuses on a different aspect of setting up Dreamfinder for a
/// team: linking the workspace, mapping team members, seeding projects,
/// capturing knowledge, and delivering the dream primer.
enum KickstartStep {
  workspace(1, 'Workspace Setup'),
  roster(2, 'Team Roster'),
  projects(3, 'Project Seeding'),
  knowledge(4, 'Knowledge Dump'),
  primer(5, 'Dream Primer');

  const KickstartStep(this.number, this.label);

  /// The 1-based step number.
  final int number;

  /// A human-readable label for display in prompts.
  final String label;

  /// Returns the step matching [number], or `null` if out of range.
  static KickstartStep? fromNumber(int number) {
    for (final step in values) {
      if (step.number == number) return step;
    }
    return null;
  }
}

/// Manages kickstart state for group chats via the `bot_metadata` table.
///
/// Each group's kickstart state is stored as a JSON blob under the key
/// `kickstart::<groupId>`. The state tracks the current step number and
/// when the kickstart was started.
class KickstartState {
  KickstartState({required this.queries});

  final Queries queries;

  /// Returns the metadata key for a given group.
  static String _key(String groupId) => 'kickstart::$groupId';

  /// Returns the active kickstart step for [groupId], or `null` if no
  /// kickstart is in progress.
  KickstartStep? getActiveKickstart(String groupId) {
    final json = queries.getMetadata(_key(groupId));
    if (json == null) return null;

    final map = jsonDecode(json) as Map<String, dynamic>;
    final step = map['step'] as int?;
    if (step == null) return null;

    return KickstartStep.fromNumber(step);
  }

  /// Returns `true` if a kickstart is currently active for [groupId].
  bool isKickstartActive(String groupId) =>
      getActiveKickstart(groupId) != null;

  /// Starts a new kickstart for [groupId] at step 1 (Workspace Setup).
  ///
  /// If a kickstart is already active, this is a no-op and returns `false`.
  /// Returns `true` if the kickstart was started.
  bool startKickstart(String groupId) {
    if (isKickstartActive(groupId)) return false;

    final payload = jsonEncode(<String, dynamic>{
      'step': KickstartStep.workspace.number,
      'startedAt': DateTime.now().toUtc().toIso8601String(),
    });
    queries.setMetadata(_key(groupId), payload);
    return true;
  }

  /// Advances the kickstart for [groupId] to the next step.
  ///
  /// Returns the new [KickstartStep], or `null` if there is no active
  /// kickstart or the kickstart is already on the final step (use
  /// [completeKickstart] instead).
  KickstartStep? advanceKickstart(String groupId) {
    final json = queries.getMetadata(_key(groupId));
    if (json == null) return null;

    final map = jsonDecode(json) as Map<String, dynamic>;
    final currentStep = map['step'] as int?;
    if (currentStep == null) return null;

    final nextStep = KickstartStep.fromNumber(currentStep + 1);
    if (nextStep == null) return null; // Already on the last step.

    map['step'] = nextStep.number;
    queries.setMetadata(_key(groupId), jsonEncode(map));
    return nextStep;
  }

  /// Marks the kickstart for [groupId] as complete by removing the state.
  void completeKickstart(String groupId) {
    // Remove the metadata key — no active kickstart means it's done.
    // We use setMetadata with a sentinel value, then delete it.
    // Actually, MetadataQueries doesn't have a delete — store a completed
    // marker that getActiveKickstart ignores.
    final payload = jsonEncode(<String, dynamic>{
      'step': null,
      'completedAt': DateTime.now().toUtc().toIso8601String(),
    });
    queries.setMetadata(_key(groupId), payload);
  }
}
