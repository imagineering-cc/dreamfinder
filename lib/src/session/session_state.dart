/// Session state management — persists co-working session progress per group.
///
/// Uses the `bot_metadata` key-value table (via [MetadataQueries]) to track
/// which phase of the session flow each group is on. Keys follow the pattern
/// `session::<groupId>` with a JSON value containing the phase number,
/// timestamp, initiator, and participant list.
library;

import 'dart:convert';

import '../db/queries.dart';

/// The eight phases of a co-working session.
///
/// Each phase structures time differently: pitch sets the agenda, build phases
/// are focused work blocks, chat phases are discussion breaks, and demo is
/// the final showcase.
enum SessionPhase {
  pitch(1, 'Pitch'),
  build1(2, 'Build 1'),
  chat1(3, 'Chat 1'),
  build2(4, 'Build 2'),
  chat2(5, 'Chat 2'),
  build3(6, 'Build 3'),
  chat3(7, 'Chat 3'),
  demo(8, 'Demo');

  const SessionPhase(this.number, this.label);

  /// The 1-based phase number.
  final int number;

  /// A human-readable label for display in prompts.
  final String label;

  /// Returns the phase matching [number], or `null` if out of range.
  static SessionPhase? fromNumber(int number) {
    for (final phase in values) {
      if (phase.number == number) return phase;
    }
    return null;
  }
}

/// Manages session state for group chats via the `bot_metadata` table.
///
/// Sessions are group-only (no DM reverse-lookup needed). State is stored
/// under `session::<groupId>` with a JSON payload containing the current
/// phase, start time, initiator ID, and participant list.
class SessionState {
  /// Creates a [SessionState] backed by the given [queries] instance.
  SessionState({required this.queries});

  /// The database queries used for metadata persistence.
  final Queries queries;

  /// Returns the metadata key for a given group.
  static String _key(String groupId) => 'session::$groupId';

  /// Returns the active session phase for [groupId], or `null` if no
  /// session is in progress.
  SessionPhase? getActiveSession(String groupId) {
    final json = queries.getMetadata(_key(groupId));
    if (json == null) return null;

    final map = jsonDecode(json) as Map<String, dynamic>;
    final phase = map['phase'] as int?;
    if (phase == null) return null;

    return SessionPhase.fromNumber(phase);
  }

  /// Returns `true` if a session is currently active for [groupId].
  bool isSessionActive(String groupId) => getActiveSession(groupId) != null;

  /// Starts a new session for [groupId] at phase 1 (Pitch).
  ///
  /// The [initiatorId] is stored as the user who kicked off the session.
  /// The initiator is automatically added to the participant list.
  ///
  /// If a session is already active, this is a no-op and returns `false`.
  /// Returns `true` if the session was started.
  bool startSession(String groupId, {required String initiatorId}) {
    if (isSessionActive(groupId)) return false;

    final payload = jsonEncode(<String, dynamic>{
      'phase': SessionPhase.pitch.number,
      'startedAt': DateTime.now().toUtc().toIso8601String(),
      'initiatorId': initiatorId,
      'participants': <String>[initiatorId],
    });
    queries.setMetadata(_key(groupId), payload);
    return true;
  }

  /// Advances the session for [groupId] to the next phase.
  ///
  /// Returns the new [SessionPhase], or `null` if there is no active
  /// session or the session is already on the final phase (use
  /// [endSession] instead).
  SessionPhase? advanceSession(String groupId) {
    final json = queries.getMetadata(_key(groupId));
    if (json == null) return null;

    final map = jsonDecode(json) as Map<String, dynamic>;
    final currentPhase = map['phase'] as int?;
    if (currentPhase == null) return null;

    final nextPhase = SessionPhase.fromNumber(currentPhase + 1);
    if (nextPhase == null) return null; // Already on the last phase.

    map['phase'] = nextPhase.number;
    queries.setMetadata(_key(groupId), jsonEncode(map));
    return nextPhase;
  }

  /// Ends the session for [groupId] by clearing the active state.
  ///
  /// Stores a completed marker so the session history is preserved but
  /// [getActiveSession] returns `null`.
  void endSession(String groupId) {
    final payload = jsonEncode(<String, dynamic>{
      'phase': null,
      'completedAt': DateTime.now().toUtc().toIso8601String(),
    });
    queries.setMetadata(_key(groupId), payload);
  }

  /// Adds a participant to the active session for [groupId].
  ///
  /// Returns `true` if the participant was added, `false` if no session
  /// is active or the user is already a participant.
  bool addParticipant(String groupId, String userId) {
    final json = queries.getMetadata(_key(groupId));
    if (json == null) return false;

    final map = jsonDecode(json) as Map<String, dynamic>;
    if (map['phase'] == null) return false; // Session completed.

    final participants = List<String>.from(
      map['participants'] as List<dynamic>? ?? <String>[],
    );

    if (participants.contains(userId)) return false;

    participants.add(userId);
    map['participants'] = participants;
    queries.setMetadata(_key(groupId), jsonEncode(map));
    return true;
  }

  /// Returns the list of participant IDs for the session in [groupId].
  ///
  /// Returns an empty list if no session is active.
  List<String> getParticipants(String groupId) {
    final json = queries.getMetadata(_key(groupId));
    if (json == null) return <String>[];

    final map = jsonDecode(json) as Map<String, dynamic>;
    if (map['phase'] == null) return <String>[]; // Session completed.

    return List<String>.from(
      map['participants'] as List<dynamic>? ?? <String>[],
    );
  }
}
