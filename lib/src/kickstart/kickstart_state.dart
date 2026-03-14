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
/// Uses a dual-key lookup so DMs can be correlated back to the originating
/// group:
/// - `kickstart::<groupId>` → `{step, startedAt, initiatorUuid}`
/// - `kickstart-dm::<userUuid>` → `{groupId}` (reverse lookup)
class KickstartState {
  KickstartState({required this.queries});

  final Queries queries;

  /// Returns the metadata key for a given group.
  static String _key(String groupId) => 'kickstart::$groupId';

  /// Returns the reverse-lookup key for a user's DM.
  static String _dmKey(String initiatorUuid) => 'kickstart-dm::$initiatorUuid';

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
  /// The [initiatorUuid] is stored so DMs from this user can be routed back to
  /// the correct group's kickstart flow.
  ///
  /// If a kickstart is already active, this is a no-op and returns `false`.
  /// Returns `true` if the kickstart was started.
  bool startKickstart(String groupId, {required String initiatorUuid}) {
    if (isKickstartActive(groupId)) return false;

    final payload = jsonEncode(<String, dynamic>{
      'step': KickstartStep.workspace.number,
      'startedAt': DateTime.now().toUtc().toIso8601String(),
      'initiatorUuid': initiatorUuid,
    });
    queries.setMetadata(_key(groupId), payload);

    // Reverse-lookup key so DMs can find the group.
    final dmPayload = jsonEncode(<String, dynamic>{'groupId': groupId});
    queries.setMetadata(_dmKey(initiatorUuid), dmPayload);

    return true;
  }

  /// Returns the group ID and current step for a user's active kickstart,
  /// or `null` if this user has no active kickstart.
  ///
  /// Used by the message loop to detect DMs from users mid-kickstart.
  ({String groupId, KickstartStep step})? getKickstartForUser(
    String initiatorUuid,
  ) {
    final dmJson = queries.getMetadata(_dmKey(initiatorUuid));
    if (dmJson == null) return null;

    final dmMap = jsonDecode(dmJson) as Map<String, dynamic>;
    final groupId = dmMap['groupId'] as String?;
    if (groupId == null) return null;

    final step = getActiveKickstart(groupId);
    if (step == null) return null;

    return (groupId: groupId, step: step);
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
  ///
  /// Clears both the group key and the user's DM reverse-lookup key.
  void completeKickstart(String groupId) {
    // Read the initiatorUuid before clearing so we can remove the DM key.
    final json = queries.getMetadata(_key(groupId));
    if (json != null) {
      final map = jsonDecode(json) as Map<String, dynamic>;
      final initiatorUuid = map['initiatorUuid'] as String?;
      if (initiatorUuid != null) {
        // Clear the reverse-lookup key. MetadataQueries has no delete, so
        // store a completed marker that getKickstartForUser ignores (the
        // group key's step will be null → getActiveKickstart returns null).
        final dmPayload = jsonEncode(<String, dynamic>{
          'groupId': groupId,
          'completedAt': DateTime.now().toUtc().toIso8601String(),
        });
        queries.setMetadata(_dmKey(initiatorUuid), dmPayload);
      }
    }

    // Store a completed marker that getActiveKickstart ignores.
    final payload = jsonEncode(<String, dynamic>{
      'step': null,
      'completedAt': DateTime.now().toUtc().toIso8601String(),
    });
    queries.setMetadata(_key(groupId), payload);
  }
}
