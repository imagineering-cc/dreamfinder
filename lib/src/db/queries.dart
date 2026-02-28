/// Query wrapper functions for the Figment domain tables.
///
/// All functions are synchronous (sqlite3 is sync). Organized by domain:
/// workspace links, user links, default board config, reminders, OAuth,
/// bot identity, standup config/sessions/responses, and calendar reminders.
library;

import 'database.dart';
import 'schema.dart';

/// Repository of query functions for the 10 domain tables.
///
/// Constructed with a [BotDatabase] so tests can inject an in-memory instance.
class Queries {
  Queries(this._db);

  final BotDatabase _db;

  // -------------------------------------------------------------------------
  // Workspace Links
  // -------------------------------------------------------------------------

  /// Returns the workspace link for [signalGroupId], or `null` if none.
  SignalWorkspaceLink? getWorkspaceLink(String signalGroupId) {
    final rows = _db.handle.select(
      'SELECT * FROM signal_workspace_links WHERE signal_group_id = ?',
      [signalGroupId],
    );
    if (rows.isEmpty) return null;
    return _workspaceLinkFromRow(rows.first);
  }

  /// Creates a new workspace link.
  void createWorkspaceLink({
    required String signalGroupId,
    required String workspacePublicId,
    required String workspaceName,
    required String createdByUuid,
  }) {
    _db.handle.execute(
      'INSERT INTO signal_workspace_links '
      '(signal_group_id, workspace_public_id, workspace_name, created_by_uuid) '
      'VALUES (?, ?, ?, ?)',
      [signalGroupId, workspacePublicId, workspaceName, createdByUuid],
    );
  }

  /// Deletes the workspace link for [signalGroupId].
  void deleteWorkspaceLink(String signalGroupId) {
    _db.handle.execute(
      'DELETE FROM signal_workspace_links WHERE signal_group_id = ?',
      [signalGroupId],
    );
  }

  /// Returns all workspace links.
  List<SignalWorkspaceLink> getAllWorkspaceLinks() {
    final rows = _db.handle.select('SELECT * FROM signal_workspace_links');
    return [for (final row in rows) _workspaceLinkFromRow(row)];
  }

  // -------------------------------------------------------------------------
  // User Links
  // -------------------------------------------------------------------------

  /// Returns the user link for [signalUuid], or `null` if none.
  SignalUserLink? getUserLink(String signalUuid) {
    final rows = _db.handle.select(
      'SELECT * FROM signal_user_links WHERE signal_uuid = ?',
      [signalUuid],
    );
    if (rows.isEmpty) return null;
    return _userLinkFromRow(rows.first);
  }

  /// Creates a new user link.
  void createUserLink({
    required String signalUuid,
    required String kanUserEmail,
    String? signalDisplayName,
    String? workspaceMemberPublicId,
    String? createdByUuid,
  }) {
    _db.handle.execute(
      'INSERT INTO signal_user_links '
      '(signal_uuid, kan_user_email, signal_display_name, '
      'workspace_member_public_id, created_by_uuid) '
      'VALUES (?, ?, ?, ?, ?)',
      [
        signalUuid,
        kanUserEmail,
        signalDisplayName,
        workspaceMemberPublicId,
        createdByUuid,
      ],
    );
  }

  /// Updates fields on the user link for [signalUuid].
  ///
  /// Only non-null parameters are applied.
  void updateUserLink(
    String signalUuid, {
    String? kanUserEmail,
    String? signalDisplayName,
    String? workspaceMemberPublicId,
  }) {
    final sets = <String>[];
    final params = <Object?>[];

    if (kanUserEmail != null) {
      sets.add('kan_user_email = ?');
      params.add(kanUserEmail);
    }
    if (signalDisplayName != null) {
      sets.add('signal_display_name = ?');
      params.add(signalDisplayName);
    }
    if (workspaceMemberPublicId != null) {
      sets.add('workspace_member_public_id = ?');
      params.add(workspaceMemberPublicId);
    }

    if (sets.isEmpty) return;

    params.add(signalUuid);
    _db.handle.execute(
      'UPDATE signal_user_links SET ${sets.join(', ')} WHERE signal_uuid = ?',
      params,
    );
  }

  /// Deletes the user link for [signalUuid].
  void deleteUserLink(String signalUuid) {
    _db.handle.execute(
      'DELETE FROM signal_user_links WHERE signal_uuid = ?',
      [signalUuid],
    );
  }

  /// Returns all user links.
  List<SignalUserLink> getAllUserLinks() {
    final rows = _db.handle.select('SELECT * FROM signal_user_links');
    return [for (final row in rows) _userLinkFromRow(row)];
  }

  /// Returns the user link matching [email], or `null` if none.
  SignalUserLink? getUserLinkByEmail(String email) {
    final rows = _db.handle.select(
      'SELECT * FROM signal_user_links WHERE kan_user_email = ?',
      [email],
    );
    if (rows.isEmpty) return null;
    return _userLinkFromRow(rows.first);
  }

  // -------------------------------------------------------------------------
  // Default Board Config
  // -------------------------------------------------------------------------

  /// Returns the default board config for [signalGroupId], or `null`.
  DefaultBoardConfigRecord? getDefaultBoardConfig(String signalGroupId) {
    final rows = _db.handle.select(
      'SELECT * FROM default_board_config WHERE signal_group_id = ?',
      [signalGroupId],
    );
    if (rows.isEmpty) return null;
    return _boardConfigFromRow(rows.first);
  }

  /// Inserts or updates the default board config for a group.
  void upsertDefaultBoardConfig({
    required String signalGroupId,
    required String boardPublicId,
    required String listPublicId,
    required String boardName,
    required String listName,
  }) {
    _db.handle.execute(
      'INSERT INTO default_board_config '
      '(signal_group_id, board_public_id, list_public_id, board_name, list_name) '
      'VALUES (?, ?, ?, ?, ?) '
      'ON CONFLICT(signal_group_id) DO UPDATE SET '
      'board_public_id = excluded.board_public_id, '
      'list_public_id = excluded.list_public_id, '
      'board_name = excluded.board_name, '
      'list_name = excluded.list_name, '
      "updated_at = datetime('now')",
      [signalGroupId, boardPublicId, listPublicId, boardName, listName],
    );
  }

  // -------------------------------------------------------------------------
  // Reminders
  // -------------------------------------------------------------------------

  /// Returns the last reminder for a card/group/type combo, or `null`.
  SentReminder? getLastReminder(
    String cardPublicId,
    String signalGroupId, {
    ReminderType reminderType = ReminderType.overdue,
  }) {
    final rows = _db.handle.select(
      'SELECT * FROM sent_reminders '
      'WHERE card_public_id = ? AND signal_group_id = ? AND reminder_type = ?',
      [cardPublicId, signalGroupId, reminderType.dbValue],
    );
    if (rows.isEmpty) return null;
    return _reminderFromRow(rows.first);
  }

  /// Records or updates a reminder for the given card/group/type.
  void upsertReminder(
    String cardPublicId,
    String signalGroupId, {
    ReminderType reminderType = ReminderType.overdue,
  }) {
    _db.handle.execute(
      'INSERT INTO sent_reminders '
      '(card_public_id, signal_group_id, reminder_type, last_reminder_at) '
      "VALUES (?, ?, ?, datetime('now')) "
      'ON CONFLICT(card_public_id, signal_group_id, reminder_type) DO UPDATE SET '
      "last_reminder_at = datetime('now')",
      [cardPublicId, signalGroupId, reminderType.dbValue],
    );
  }

  /// Deletes reminders older than [olderThanDays] days.
  void cleanOldReminders({int olderThanDays = 7}) {
    _db.handle.execute(
      'DELETE FROM sent_reminders '
      "WHERE last_reminder_at < datetime('now', ?)",
      ['-$olderThanDays days'],
    );
  }

  // -------------------------------------------------------------------------
  // OAuth Tokens
  // -------------------------------------------------------------------------

  /// Returns the token value for [tokenType], or `null`.
  String? getOAuthToken(String tokenType) {
    final rows = _db.handle.select(
      'SELECT token_value FROM oauth_tokens WHERE token_type = ?',
      [tokenType],
    );
    if (rows.isEmpty) return null;
    return rows.first['token_value'] as String;
  }

  /// Saves or updates an OAuth token.
  void saveOAuthToken(String tokenType, String tokenValue, {int? expiresAt}) {
    _db.handle.execute(
      'INSERT INTO oauth_tokens (token_type, token_value, expires_at, updated_at) '
      "VALUES (?, ?, ?, datetime('now')) "
      'ON CONFLICT(token_type) DO UPDATE SET '
      'token_value = excluded.token_value, '
      'expires_at = excluded.expires_at, '
      "updated_at = datetime('now')",
      [tokenType, tokenValue, expiresAt],
    );
  }

  // -------------------------------------------------------------------------
  // Bot Identity
  // -------------------------------------------------------------------------

  /// Returns the most recently chosen bot identity, or `null`.
  BotIdentityRecord? getBotIdentity() {
    final rows = _db.handle.select(
      'SELECT * FROM bot_identity ORDER BY chosen_at DESC, id DESC LIMIT 1',
    );
    if (rows.isEmpty) return null;
    return _botIdentityFromRow(rows.first);
  }

  /// Saves a new bot identity record.
  void saveBotIdentity({
    required String name,
    required String pronouns,
    required String tone,
    String? toneDescription,
    String? chosenInGroupId,
  }) {
    _db.handle.execute(
      'INSERT INTO bot_identity '
      '(name, pronouns, tone, tone_description, chosen_in_group_id) '
      'VALUES (?, ?, ?, ?, ?)',
      [name, pronouns, tone, toneDescription, chosenInGroupId],
    );
  }

  // -------------------------------------------------------------------------
  // Standup Config
  // -------------------------------------------------------------------------

  /// Returns the standup config for [signalGroupId], or `null`.
  StandupConfigRecord? getStandupConfig(String signalGroupId) {
    final rows = _db.handle.select(
      'SELECT * FROM standup_config WHERE signal_group_id = ?',
      [signalGroupId],
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
    required String signalGroupId,
    bool? enabled,
    int? promptHour,
    int? summaryHour,
    String? timezone,
    bool? skipBreakDays,
    bool? skipWeekends,
    int? nudgeHour,
  }) {
    final existing = getStandupConfig(signalGroupId);

    if (existing == null) {
      // First time — insert with provided values or defaults.
      _db.handle.execute(
        'INSERT INTO standup_config '
        '(signal_group_id, enabled, prompt_hour, summary_hour, timezone, '
        'skip_break_days, skip_weekends, nudge_hour) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        [
          signalGroupId,
          (enabled ?? true) ? 1 : 0,
          promptHour ?? 9,
          summaryHour ?? 17,
          timezone ?? 'Australia/Sydney',
          (skipBreakDays ?? true) ? 1 : 0,
          (skipWeekends ?? true) ? 1 : 0,
          nudgeHour,
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

    if (sets.isEmpty) return;

    params.add(signalGroupId);
    _db.handle.execute(
      'UPDATE standup_config SET ${sets.join(', ')} '
      'WHERE signal_group_id = ?',
      params,
    );
  }

  /// Returns all standup configs.
  List<StandupConfigRecord> getAllStandupConfigs() {
    final rows = _db.handle.select('SELECT * FROM standup_config');
    return [for (final row in rows) _standupConfigFromRow(row)];
  }

  // -------------------------------------------------------------------------
  // Standup Sessions
  // -------------------------------------------------------------------------

  /// Returns the standup session for [signalGroupId] on [date], or `null`.
  StandupSession? getActiveStandupSession(String signalGroupId, String date) {
    final rows = _db.handle.select(
      'SELECT * FROM standup_sessions '
      'WHERE signal_group_id = ? AND date = ?',
      [signalGroupId, date],
    );
    if (rows.isEmpty) return null;
    return _standupSessionFromRow(rows.first);
  }

  /// Creates a new standup session.
  void createStandupSession({
    required String signalGroupId,
    required String date,
    String? promptMessageId,
    StandupSessionStatus status = StandupSessionStatus.active,
  }) {
    _db.handle.execute(
      'INSERT INTO standup_sessions '
      '(signal_group_id, date, prompt_message_id, status) '
      'VALUES (?, ?, ?, ?)',
      [signalGroupId, date, promptMessageId, status.dbValue],
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
    _db.handle.execute(
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
    required String signalUuid,
    String? signalDisplayName,
    String? yesterday,
    String? today,
    String? blockers,
    String? rawMessage,
  }) {
    _db.handle.execute(
      'INSERT INTO standup_responses '
      '(session_id, signal_uuid, signal_display_name, '
      'yesterday, today, blockers, raw_message) '
      'VALUES (?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(session_id, signal_uuid) DO UPDATE SET '
      'signal_display_name = excluded.signal_display_name, '
      'yesterday = excluded.yesterday, '
      'today = excluded.today, '
      'blockers = excluded.blockers, '
      'raw_message = excluded.raw_message',
      [
        sessionId,
        signalUuid,
        signalDisplayName,
        yesterday,
        today,
        blockers,
        rawMessage,
      ],
    );
  }

  /// Returns all standup responses for [sessionId].
  List<StandupResponse> getStandupResponses(int sessionId) {
    final rows = _db.handle.select(
      'SELECT * FROM standup_responses WHERE session_id = ?',
      [sessionId],
    );
    return [for (final row in rows) _standupResponseFromRow(row)];
  }

  // -------------------------------------------------------------------------
  // Calendar Reminders
  // -------------------------------------------------------------------------

  /// Returns `true` if a reminder has already been sent for this event/group/window.
  bool hasCalendarReminderBeenSent(
    String eventUid,
    String signalGroupId,
    CalendarReminderWindow reminderWindow,
  ) {
    final rows = _db.handle.select(
      'SELECT 1 FROM calendar_reminders '
      'WHERE event_uid = ? AND signal_group_id = ? AND reminder_window = ?',
      [eventUid, signalGroupId, reminderWindow.dbValue],
    );
    return rows.isNotEmpty;
  }

  /// Records a calendar reminder as sent (idempotent).
  void recordCalendarReminder(
    String eventUid,
    String signalGroupId,
    CalendarReminderWindow reminderWindow,
  ) {
    _db.handle.execute(
      'INSERT OR IGNORE INTO calendar_reminders '
      '(event_uid, signal_group_id, reminder_window, sent_at) '
      "VALUES (?, ?, ?, datetime('now'))",
      [eventUid, signalGroupId, reminderWindow.dbValue],
    );
  }

  /// Deletes calendar reminders older than [olderThanDays] days.
  void cleanOldCalendarReminders({int olderThanDays = 7}) {
    _db.handle.execute(
      "DELETE FROM calendar_reminders WHERE sent_at < datetime('now', ?)",
      ['-$olderThanDays days'],
    );
  }

  // -------------------------------------------------------------------------
  // Row mappers
  // -------------------------------------------------------------------------

  SignalWorkspaceLink _workspaceLinkFromRow(Map<String, Object?> row) {
    return SignalWorkspaceLink(
      id: row['id']! as int,
      signalGroupId: row['signal_group_id']! as String,
      workspacePublicId: row['workspace_public_id']! as String,
      workspaceName: row['workspace_name']! as String,
      createdAt: row['created_at']! as String,
      createdByUuid: row['created_by_uuid']! as String,
    );
  }

  SignalUserLink _userLinkFromRow(Map<String, Object?> row) {
    return SignalUserLink(
      id: row['id']! as int,
      signalUuid: row['signal_uuid']! as String,
      signalDisplayName: row['signal_display_name'] as String?,
      kanUserEmail: row['kan_user_email']! as String,
      workspaceMemberPublicId: row['workspace_member_public_id'] as String?,
      createdAt: row['created_at']! as String,
      createdByUuid: row['created_by_uuid'] as String?,
    );
  }

  DefaultBoardConfigRecord _boardConfigFromRow(Map<String, Object?> row) {
    return DefaultBoardConfigRecord(
      id: row['id']! as int,
      signalGroupId: row['signal_group_id']! as String,
      boardPublicId: row['board_public_id']! as String,
      listPublicId: row['list_public_id']! as String,
      boardName: row['board_name']! as String,
      listName: row['list_name']! as String,
      updatedAt: row['updated_at']! as String,
    );
  }

  SentReminder _reminderFromRow(Map<String, Object?> row) {
    return SentReminder(
      id: row['id']! as int,
      cardPublicId: row['card_public_id']! as String,
      signalGroupId: row['signal_group_id']! as String,
      reminderType: ReminderType.fromDb(row['reminder_type']! as String),
      lastReminderAt: row['last_reminder_at']! as String,
    );
  }

  BotIdentityRecord _botIdentityFromRow(Map<String, Object?> row) {
    return BotIdentityRecord(
      id: row['id']! as int,
      name: row['name']! as String,
      pronouns: row['pronouns']! as String,
      tone: row['tone']! as String,
      toneDescription: row['tone_description'] as String?,
      chosenAt: row['chosen_at']! as String,
      chosenInGroupId: row['chosen_in_group_id'] as String?,
    );
  }

  StandupConfigRecord _standupConfigFromRow(Map<String, Object?> row) {
    return StandupConfigRecord(
      id: row['id']! as int,
      signalGroupId: row['signal_group_id']! as String,
      enabled: row['enabled']! as int == 1,
      promptHour: row['prompt_hour']! as int,
      summaryHour: row['summary_hour']! as int,
      timezone: row['timezone']! as String,
      skipBreakDays: row['skip_break_days']! as int == 1,
      skipWeekends: row['skip_weekends']! as int == 1,
      nudgeHour: row['nudge_hour'] as int?,
    );
  }

  StandupSession _standupSessionFromRow(Map<String, Object?> row) {
    return StandupSession(
      id: row['id']! as int,
      signalGroupId: row['signal_group_id']! as String,
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
      signalUuid: row['signal_uuid']! as String,
      signalDisplayName: row['signal_display_name'] as String?,
      yesterday: row['yesterday'] as String?,
      today: row['today'] as String?,
      blockers: row['blockers'] as String?,
      rawMessage: row['raw_message'] as String?,
    );
  }
}
