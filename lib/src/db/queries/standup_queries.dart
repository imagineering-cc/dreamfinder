/// Standup queries — config, sessions, and responses.
library;

import '../database.dart';
import '../schema.dart';

/// Mixin providing standup config, session, and response CRUD operations.
mixin StandupQueries {
  /// The database handle. Provided by the mixing-in class.
  BotDatabase get db;

  // -------------------------------------------------------------------------
  // Standup Config
  // -------------------------------------------------------------------------

  /// Returns the standup config for [groupId], or `null`.
  StandupConfigRecord? getStandupConfig(String groupId) {
    final rows = db.handle.select(
      'SELECT * FROM standup_config WHERE group_id = ?',
      [groupId],
    );
    if (rows.isEmpty) return null;
    return _standupConfigFromRow(rows.first);
  }

  /// Inserts or partially updates the standup config for a group.
  ///
  /// On insert, uses the provided values or sensible defaults.
  /// On update, only modifies fields that are explicitly provided —
  /// omitted fields retain their existing values.
  void upsertStandupConfig({
    required String groupId,
    bool? enabled,
    int? promptHour,
    int? summaryHour,
    String? timezone,
    bool? skipBreakDays,
    bool? skipWeekends,
    int? nudgeHour,
    int? radarHour,
  }) {
    final existing = getStandupConfig(groupId);

    if (existing == null) {
      // First time — insert with provided values or defaults.
      db.handle.execute(
        'INSERT INTO standup_config '
        '(group_id, enabled, prompt_hour, summary_hour, timezone, '
        'skip_break_days, skip_weekends, nudge_hour, radar_hour) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          groupId,
          (enabled ?? true) ? 1 : 0,
          promptHour ?? 9,
          summaryHour ?? 17,
          timezone ?? 'Australia/Sydney',
          (skipBreakDays ?? true) ? 1 : 0,
          (skipWeekends ?? true) ? 1 : 0,
          nudgeHour,
          radarHour,
        ],
      );
      return;
    }

    // Partial update — only set fields that were explicitly provided.
    final sets = <String>[];
    final params = <Object?>[];

    if (enabled != null) {
      sets.add('enabled = ?');
      params.add(enabled ? 1 : 0);
    }
    if (promptHour != null) {
      sets.add('prompt_hour = ?');
      params.add(promptHour);
    }
    if (summaryHour != null) {
      sets.add('summary_hour = ?');
      params.add(summaryHour);
    }
    if (timezone != null) {
      sets.add('timezone = ?');
      params.add(timezone);
    }
    if (skipBreakDays != null) {
      sets.add('skip_break_days = ?');
      params.add(skipBreakDays ? 1 : 0);
    }
    if (skipWeekends != null) {
      sets.add('skip_weekends = ?');
      params.add(skipWeekends ? 1 : 0);
    }
    if (nudgeHour != null) {
      sets.add('nudge_hour = ?');
      params.add(nudgeHour);
    }
    if (radarHour != null) {
      sets.add('radar_hour = ?');
      params.add(radarHour);
    }

    if (sets.isEmpty) return;

    params.add(groupId);
    db.handle.execute(
      'UPDATE standup_config SET ${sets.join(', ')} '
      'WHERE group_id = ?',
      params,
    );
  }

  /// Returns all standup configs.
  List<StandupConfigRecord> getAllStandupConfigs() {
    final rows = db.handle.select('SELECT * FROM standup_config');
    return [for (final row in rows) _standupConfigFromRow(row)];
  }

  // -------------------------------------------------------------------------
  // Standup Sessions
  // -------------------------------------------------------------------------

  /// Returns the standup session for [groupId] on [date], or `null`.
  StandupSession? getActiveStandupSession(String groupId, String date) {
    final rows = db.handle.select(
      'SELECT * FROM standup_sessions '
      'WHERE group_id = ? AND date = ?',
      [groupId, date],
    );
    if (rows.isEmpty) return null;
    return _standupSessionFromRow(rows.first);
  }

  /// Creates a new standup session.
  void createStandupSession({
    required String groupId,
    required String date,
    String? promptMessageId,
    StandupSessionStatus status = StandupSessionStatus.active,
  }) {
    db.handle.execute(
      'INSERT INTO standup_sessions '
      '(group_id, date, prompt_message_id, status) '
      'VALUES (?, ?, ?, ?)',
      [groupId, date, promptMessageId, status.dbValue],
    );
  }

  /// Updates fields on an existing standup session.
  void updateStandupSession(
    int id, {
    String? promptMessageId,
    String? summaryMessageId,
    StandupSessionStatus? status,
    int? nudgedAt,
  }) {
    final sets = <String>[];
    final params = <Object?>[];

    if (promptMessageId != null) {
      sets.add('prompt_message_id = ?');
      params.add(promptMessageId);
    }
    if (summaryMessageId != null) {
      sets.add('summary_message_id = ?');
      params.add(summaryMessageId);
    }
    if (status != null) {
      sets.add('status = ?');
      params.add(status.dbValue);
    }
    if (nudgedAt != null) {
      sets.add('nudged_at = ?');
      params.add(nudgedAt);
    }

    if (sets.isEmpty) return;

    params.add(id);
    db.handle.execute(
      'UPDATE standup_sessions SET ${sets.join(', ')} WHERE id = ?',
      params,
    );
  }

  // -------------------------------------------------------------------------
  // Standup Responses
  // -------------------------------------------------------------------------

  /// Inserts or updates a standup response for a session/user.
  void upsertStandupResponse({
    required int sessionId,
    required String userId,
    String? displayName,
    String? yesterday,
    String? today,
    String? blockers,
    String? rawMessage,
  }) {
    db.handle.execute(
      'INSERT INTO standup_responses '
      '(session_id, user_id, display_name, '
      'yesterday, today, blockers, raw_message) '
      'VALUES (?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(session_id, user_id) DO UPDATE SET '
      'display_name = excluded.display_name, '
      'yesterday = excluded.yesterday, '
      'today = excluded.today, '
      'blockers = excluded.blockers, '
      'raw_message = excluded.raw_message',
      [
        sessionId,
        userId,
        displayName,
        yesterday,
        today,
        blockers,
        rawMessage,
      ],
    );
  }

  /// Returns all standup responses for [sessionId].
  List<StandupResponse> getStandupResponses(int sessionId) {
    final rows = db.handle.select(
      'SELECT * FROM standup_responses WHERE session_id = ?',
      [sessionId],
    );
    return [for (final row in rows) _standupResponseFromRow(row)];
  }

  // -------------------------------------------------------------------------
  // Row mappers
  // -------------------------------------------------------------------------

  StandupConfigRecord _standupConfigFromRow(Map<String, Object?> row) {
    return StandupConfigRecord(
      id: row['id']! as int,
      groupId: row['group_id']! as String,
      enabled: row['enabled']! as int == 1,
      promptHour: row['prompt_hour']! as int,
      summaryHour: row['summary_hour']! as int,
      timezone: row['timezone']! as String,
      skipBreakDays: row['skip_break_days']! as int == 1,
      skipWeekends: row['skip_weekends']! as int == 1,
      nudgeHour: row['nudge_hour'] as int?,
      radarHour: row['radar_hour'] as int?,
    );
  }

  StandupSession _standupSessionFromRow(Map<String, Object?> row) {
    return StandupSession(
      id: row['id']! as int,
      groupId: row['group_id']! as String,
      date: row['date']! as String,
      promptMessageId: row['prompt_message_id'] as String?,
      summaryMessageId: row['summary_message_id'] as String?,
      status: StandupSessionStatus.fromDb(row['status']! as String),
      nudgedAt: row['nudged_at'] as int?,
    );
  }

  StandupResponse _standupResponseFromRow(Map<String, Object?> row) {
    return StandupResponse(
      id: row['id']! as int,
      sessionId: row['session_id']! as int,
      userId: row['user_id']! as String,
      displayName: row['display_name'] as String?,
      yesterday: row['yesterday'] as String?,
      today: row['today'] as String?,
      blockers: row['blockers'] as String?,
      rawMessage: row['raw_message'] as String?,
    );
  }
}
