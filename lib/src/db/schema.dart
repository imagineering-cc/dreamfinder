/// Schema model classes and enums for the Dreamfinder database.
///
/// These types represent rows from the 10 domain tables adapted from
/// xdeca-pm-bot (Telegram) to Signal (now called Dreamfinder). Key differences from Telegram:
/// - Group IDs are base64 strings (not integers)
/// - User IDs are UUIDs (not integers)
/// - Display names replace @usernames
/// - No topic threads or inline polls
library;

/// Valid reminder types for card-based reminders.
enum ReminderType {
  overdue,
  noDueDate,
  vague,
  stale,
  unassigned,
  noTasks;

  /// Database column value (snake_case).
  String get dbValue => switch (this) {
        overdue => 'overdue',
        noDueDate => 'no_due_date',
        vague => 'vague',
        stale => 'stale',
        unassigned => 'unassigned',
        noTasks => 'no_tasks',
      };

  /// Parses a database column value into a [ReminderType].
  static ReminderType fromDb(String value) => switch (value) {
        'overdue' => overdue,
        'no_due_date' => noDueDate,
        'vague' => vague,
        'stale' => stale,
        'unassigned' => unassigned,
        'no_tasks' => noTasks,
        _ => throw ArgumentError('Unknown reminder type: $value'),
      };
}

/// Status of a standup session for a given day.
enum StandupSessionStatus {
  active,
  summarized,
  skipped;

  /// Database column value.
  String get dbValue => name;

  /// Parses a database column value into a [StandupSessionStatus].
  static StandupSessionStatus fromDb(String value) => switch (value) {
        'active' => active,
        'summarized' => summarized,
        'skipped' => skipped,
        _ => throw ArgumentError('Unknown standup session status: $value'),
      };
}

/// Calendar reminder window granularity.
enum CalendarReminderWindow {
  twentyFourHours,
  oneHour,
  fifteenMinutes;

  /// Database column value.
  String get dbValue => switch (this) {
        twentyFourHours => '24h',
        oneHour => '1h',
        fifteenMinutes => '15m',
      };

  /// Parses a database column value into a [CalendarReminderWindow].
  static CalendarReminderWindow fromDb(String value) => switch (value) {
        '24h' => twentyFourHours,
        '1h' => oneHour,
        '15m' => fifteenMinutes,
        _ => throw ArgumentError('Unknown calendar reminder window: $value'),
      };
}

// ---------------------------------------------------------------------------
// Model classes — one per table
// ---------------------------------------------------------------------------

/// Maps a Signal group to a Kan workspace.
class SignalWorkspaceLink {
  const SignalWorkspaceLink({
    required this.id,
    required this.signalGroupId,
    required this.workspacePublicId,
    required this.workspaceName,
    required this.createdAt,
    required this.createdByUuid,
  });

  final int id;
  final String signalGroupId;
  final String workspacePublicId;
  final String workspaceName;
  final String createdAt;
  final String createdByUuid;
}

/// Maps a Signal user (UUID) to their Kan account.
class SignalUserLink {
  const SignalUserLink({
    required this.id,
    required this.signalUuid,
    this.signalDisplayName,
    required this.kanUserEmail,
    this.workspaceMemberPublicId,
    required this.createdAt,
    this.createdByUuid,
  });

  final int id;
  final String signalUuid;
  final String? signalDisplayName;
  final String kanUserEmail;
  final String? workspaceMemberPublicId;
  final String createdAt;
  final String? createdByUuid;
}

/// Tracks sent card reminders to avoid spamming a group.
class SentReminder {
  const SentReminder({
    required this.id,
    required this.cardPublicId,
    required this.signalGroupId,
    required this.reminderType,
    required this.lastReminderAt,
  });

  final int id;
  final String cardPublicId;
  final String signalGroupId;
  final ReminderType reminderType;
  final String lastReminderAt;
}

/// The bot's chosen identity (name, pronouns, tone).
class BotIdentityRecord {
  const BotIdentityRecord({
    required this.id,
    required this.name,
    required this.pronouns,
    required this.tone,
    this.toneDescription,
    required this.chosenAt,
    this.chosenInGroupId,
  });

  final int id;
  final String name;
  final String pronouns;
  final String tone;
  final String? toneDescription;
  final String chosenAt;
  final String? chosenInGroupId;
}

/// Default board and list for card creation in a Signal group.
class DefaultBoardConfigRecord {
  const DefaultBoardConfigRecord({
    required this.id,
    required this.signalGroupId,
    required this.boardPublicId,
    required this.listPublicId,
    required this.boardName,
    required this.listName,
    required this.updatedAt,
  });

  final int id;
  final String signalGroupId;
  final String boardPublicId;
  final String listPublicId;
  final String boardName;
  final String listName;
  final String updatedAt;
}

/// A persisted OAuth/refresh token.
class OAuthTokenRecord {
  const OAuthTokenRecord({
    required this.id,
    required this.tokenType,
    required this.tokenValue,
    this.expiresAt,
    required this.updatedAt,
  });

  final int id;
  final String tokenType;
  final String tokenValue;
  final int? expiresAt;
  final String updatedAt;
}

/// Per-group standup scheduling configuration.
class StandupConfigRecord {
  const StandupConfigRecord({
    required this.id,
    required this.signalGroupId,
    required this.enabled,
    required this.promptHour,
    required this.summaryHour,
    required this.timezone,
    required this.skipBreakDays,
    required this.skipWeekends,
    this.nudgeHour,
  });

  final int id;
  final String signalGroupId;
  final bool enabled;
  final int promptHour;
  final int summaryHour;
  final String timezone;
  final bool skipBreakDays;
  final bool skipWeekends;
  final int? nudgeHour;
}

/// A single standup session for one group on one date.
class StandupSession {
  const StandupSession({
    required this.id,
    required this.signalGroupId,
    required this.date,
    this.promptMessageId,
    this.summaryMessageId,
    required this.status,
    this.nudgedAt,
  });

  final int id;
  final String signalGroupId;
  final String date;
  final String? promptMessageId;
  final String? summaryMessageId;
  final StandupSessionStatus status;
  final int? nudgedAt;
}

/// An individual user's standup response within a session.
class StandupResponse {
  const StandupResponse({
    required this.id,
    required this.sessionId,
    required this.signalUuid,
    this.signalDisplayName,
    this.yesterday,
    this.today,
    this.blockers,
    this.rawMessage,
  });

  final int id;
  final int sessionId;
  final String signalUuid;
  final String? signalDisplayName;
  final String? yesterday;
  final String? today;
  final String? blockers;
  final String? rawMessage;
}

/// Tracks calendar event reminders sent to avoid duplicates.
class CalendarReminderRecord {
  const CalendarReminderRecord({
    required this.id,
    required this.eventUid,
    required this.signalGroupId,
    required this.reminderWindow,
    required this.sentAt,
  });

  final int id;
  final String eventUid;
  final String signalGroupId;
  final CalendarReminderWindow reminderWindow;
  final String sentAt;
}
