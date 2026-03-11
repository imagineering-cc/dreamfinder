import 'package:dreamfinder/src/db/database.dart';
import 'package:dreamfinder/src/db/queries.dart';
import 'package:dreamfinder/src/db/schema.dart';
import 'package:test/test.dart';

void main() {
  late BotDatabase db;
  late Queries q;

  setUp(() {
    db = BotDatabase.inMemory();
    q = Queries(db);
  });

  tearDown(() {
    db.close();
  });

  // -----------------------------------------------------------------------
  // Workspace Links
  // -----------------------------------------------------------------------

  group('Workspace Links', () {
    test('getWorkspaceLink returns null when none exists', () {
      expect(q.getWorkspaceLink('group-1'), isNull);
    });

    test('createWorkspaceLink then getWorkspaceLink round-trips', () {
      q.createWorkspaceLink(
        signalGroupId: 'group-1',
        workspacePublicId: 'ws-abc',
        workspaceName: 'My Workspace',
        createdByUuid: 'uuid-admin',
      );

      final link = q.getWorkspaceLink('group-1');
      expect(link, isNotNull);
      expect(link!.workspacePublicId, equals('ws-abc'));
      expect(link.workspaceName, equals('My Workspace'));
      expect(link.createdByUuid, equals('uuid-admin'));
    });

    test('deleteWorkspaceLink removes the link', () {
      q.createWorkspaceLink(
        signalGroupId: 'group-1',
        workspacePublicId: 'ws-abc',
        workspaceName: 'My Workspace',
        createdByUuid: 'uuid-admin',
      );

      q.deleteWorkspaceLink('group-1');
      expect(q.getWorkspaceLink('group-1'), isNull);
    });

    test('getAllWorkspaceLinks returns all links', () {
      q.createWorkspaceLink(
        signalGroupId: 'group-1',
        workspacePublicId: 'ws-1',
        workspaceName: 'Workspace 1',
        createdByUuid: 'uuid-a',
      );
      q.createWorkspaceLink(
        signalGroupId: 'group-2',
        workspacePublicId: 'ws-2',
        workspaceName: 'Workspace 2',
        createdByUuid: 'uuid-b',
      );

      final links = q.getAllWorkspaceLinks();
      expect(links, hasLength(2));
    });

    test('createWorkspaceLink enforces unique signalGroupId', () {
      q.createWorkspaceLink(
        signalGroupId: 'group-1',
        workspacePublicId: 'ws-1',
        workspaceName: 'First',
        createdByUuid: 'uuid-a',
      );

      expect(
        () => q.createWorkspaceLink(
          signalGroupId: 'group-1',
          workspacePublicId: 'ws-2',
          workspaceName: 'Duplicate',
          createdByUuid: 'uuid-b',
        ),
        throwsA(isA<Exception>()),
      );
    });
  });

  // -----------------------------------------------------------------------
  // User Links
  // -----------------------------------------------------------------------

  group('User Links', () {
    test('getUserLink returns null when none exists', () {
      expect(q.getUserLink('uuid-1'), isNull);
    });

    test('createUserLink then getUserLink round-trips', () {
      q.createUserLink(
        signalUuid: 'uuid-1',
        kanUserEmail: 'alice@example.com',
        signalDisplayName: 'Alice',
        createdByUuid: 'uuid-admin',
      );

      final link = q.getUserLink('uuid-1');
      expect(link, isNotNull);
      expect(link!.kanUserEmail, equals('alice@example.com'));
      expect(link.signalDisplayName, equals('Alice'));
    });

    test('updateUserLink modifies existing link', () {
      q.createUserLink(
        signalUuid: 'uuid-1',
        kanUserEmail: 'old@example.com',
      );

      q.updateUserLink('uuid-1', kanUserEmail: 'new@example.com');

      final link = q.getUserLink('uuid-1');
      expect(link!.kanUserEmail, equals('new@example.com'));
    });

    test('deleteUserLink removes the link', () {
      q.createUserLink(
        signalUuid: 'uuid-1',
        kanUserEmail: 'alice@example.com',
      );

      q.deleteUserLink('uuid-1');
      expect(q.getUserLink('uuid-1'), isNull);
    });

    test('getAllUserLinks returns all links', () {
      q.createUserLink(
        signalUuid: 'uuid-1',
        kanUserEmail: 'a@example.com',
      );
      q.createUserLink(
        signalUuid: 'uuid-2',
        kanUserEmail: 'b@example.com',
      );

      expect(q.getAllUserLinks(), hasLength(2));
    });

    test('getUserLinkByEmail finds by email', () {
      q.createUserLink(
        signalUuid: 'uuid-1',
        kanUserEmail: 'alice@example.com',
      );

      final link = q.getUserLinkByEmail('alice@example.com');
      expect(link, isNotNull);
      expect(link!.signalUuid, equals('uuid-1'));
    });

    test('getUserLinkByEmail returns null for unknown email', () {
      expect(q.getUserLinkByEmail('nobody@example.com'), isNull);
    });
  });

  // -----------------------------------------------------------------------
  // Default Board Config
  // -----------------------------------------------------------------------

  group('Default Board Config', () {
    test('getDefaultBoardConfig returns null when none exists', () {
      expect(q.getDefaultBoardConfig('group-1'), isNull);
    });

    test('upsertDefaultBoardConfig inserts new config', () {
      q.upsertDefaultBoardConfig(
        signalGroupId: 'group-1',
        boardPublicId: 'board-1',
        listPublicId: 'list-1',
        boardName: 'Sprint Board',
        listName: 'To Do',
      );

      final config = q.getDefaultBoardConfig('group-1');
      expect(config, isNotNull);
      expect(config!.boardName, equals('Sprint Board'));
      expect(config.listName, equals('To Do'));
    });

    test('upsertDefaultBoardConfig updates on conflict', () {
      q.upsertDefaultBoardConfig(
        signalGroupId: 'group-1',
        boardPublicId: 'board-1',
        listPublicId: 'list-1',
        boardName: 'Old Board',
        listName: 'Old List',
      );

      q.upsertDefaultBoardConfig(
        signalGroupId: 'group-1',
        boardPublicId: 'board-2',
        listPublicId: 'list-2',
        boardName: 'New Board',
        listName: 'New List',
      );

      final config = q.getDefaultBoardConfig('group-1');
      expect(config!.boardPublicId, equals('board-2'));
      expect(config.boardName, equals('New Board'));
    });
  });

  // -----------------------------------------------------------------------
  // Reminders
  // -----------------------------------------------------------------------

  group('Reminders', () {
    test('getLastReminder returns null when none exists', () {
      expect(q.getLastReminder('card-1', 'group-1'), isNull);
    });

    test('upsertReminder then getLastReminder round-trips', () {
      q.upsertReminder('card-1', 'group-1');

      final reminder = q.getLastReminder('card-1', 'group-1');
      expect(reminder, isNotNull);
      expect(reminder!.cardPublicId, equals('card-1'));
      expect(reminder.reminderType, equals(ReminderType.overdue));
    });

    test('upsertReminder with specific type', () {
      q.upsertReminder('card-1', 'group-1', reminderType: ReminderType.stale);

      final reminder = q.getLastReminder('card-1', 'group-1',
          reminderType: ReminderType.stale);
      expect(reminder, isNotNull);
      expect(reminder!.reminderType, equals(ReminderType.stale));
    });

    test('upsertReminder updates on duplicate key', () {
      q.upsertReminder('card-1', 'group-1');
      q.upsertReminder('card-1', 'group-1');

      // Should still be exactly one row.
      final all = db.handle.select(
        'SELECT COUNT(*) as cnt FROM sent_reminders '
        "WHERE card_public_id = 'card-1' AND signal_group_id = 'group-1'",
      );
      expect(all.first['cnt'], equals(1));
    });

    test('cleanOldReminders removes old entries', () {
      // Insert a reminder with an old timestamp.
      db.handle.execute(
        'INSERT INTO sent_reminders '
        '(card_public_id, signal_group_id, reminder_type, last_reminder_at) '
        "VALUES ('card-old', 'group-1', 'overdue', datetime('now', '-30 days'))",
      );
      q.upsertReminder('card-new', 'group-1');

      q.cleanOldReminders(olderThanDays: 7);

      expect(q.getLastReminder('card-old', 'group-1'), isNull);
      expect(q.getLastReminder('card-new', 'group-1'), isNotNull);
    });
  });

  // -----------------------------------------------------------------------
  // OAuth Tokens
  // -----------------------------------------------------------------------

  group('OAuth Tokens', () {
    test('getOAuthToken returns null when none exists', () {
      expect(q.getOAuthToken('refresh'), isNull);
    });

    test('saveOAuthToken then getOAuthToken round-trips', () {
      q.saveOAuthToken('refresh', 'token-value-123');

      expect(q.getOAuthToken('refresh'), equals('token-value-123'));
    });

    test('saveOAuthToken updates on conflict', () {
      q.saveOAuthToken('refresh', 'old-value');
      q.saveOAuthToken('refresh', 'new-value');

      expect(q.getOAuthToken('refresh'), equals('new-value'));
    });
  });

  // -----------------------------------------------------------------------
  // Bot Identity
  // -----------------------------------------------------------------------

  group('Bot Identity', () {
    test('getBotIdentity returns null when none exists', () {
      expect(q.getBotIdentity(), isNull);
    });

    test('saveBotIdentity then getBotIdentity round-trips', () {
      q.saveBotIdentity(
        name: 'Dreamfinder',
        pronouns: 'they/them',
        tone: 'playful',
      );

      final identity = q.getBotIdentity();
      expect(identity, isNotNull);
      expect(identity!.name, equals('Dreamfinder'));
      expect(identity.pronouns, equals('they/them'));
      expect(identity.tone, equals('playful'));
    });

    test('getBotIdentity returns the most recently chosen identity', () {
      q.saveBotIdentity(
        name: 'OldName',
        pronouns: 'he/him',
        tone: 'serious',
      );
      q.saveBotIdentity(
        name: 'NewName',
        pronouns: 'she/her',
        tone: 'playful',
        toneDescription: 'A playful tone',
      );

      final identity = q.getBotIdentity();
      expect(identity!.name, equals('NewName'));
      expect(identity.toneDescription, equals('A playful tone'));
    });
  });

  // -----------------------------------------------------------------------
  // Standup Config
  // -----------------------------------------------------------------------

  group('Standup Config', () {
    test('getStandupConfig returns null when none exists', () {
      expect(q.getStandupConfig('group-1'), isNull);
    });

    test('upsertStandupConfig inserts with defaults', () {
      q.upsertStandupConfig(signalGroupId: 'group-1');

      final config = q.getStandupConfig('group-1');
      expect(config, isNotNull);
      expect(config!.enabled, isTrue);
      expect(config.promptHour, equals(9));
      expect(config.summaryHour, equals(17));
      expect(config.timezone, equals('Australia/Sydney'));
      expect(config.skipWeekends, isTrue);
      expect(config.nudgeHour, isNull);
    });

    test('upsertStandupConfig does partial update on conflict', () {
      q.upsertStandupConfig(signalGroupId: 'group-1');

      // Update only promptHour, leave everything else.
      q.upsertStandupConfig(
        signalGroupId: 'group-1',
        promptHour: 10,
      );

      final config = q.getStandupConfig('group-1');
      expect(config!.promptHour, equals(10));
      // These should remain at their original values, not reset to defaults.
      expect(config.summaryHour, equals(17));
      expect(config.timezone, equals('Australia/Sydney'));
    });

    test('getAllStandupConfigs returns all configs', () {
      q.upsertStandupConfig(signalGroupId: 'group-1');
      q.upsertStandupConfig(signalGroupId: 'group-2');

      expect(q.getAllStandupConfigs(), hasLength(2));
    });
  });

  // -----------------------------------------------------------------------
  // Standup Sessions
  // -----------------------------------------------------------------------

  group('Standup Sessions', () {
    test('getActiveStandupSession returns null when none exists', () {
      expect(q.getActiveStandupSession('group-1', '2026-02-28'), isNull);
    });

    test('createStandupSession then getActiveStandupSession round-trips', () {
      q.createStandupSession(
        signalGroupId: 'group-1',
        date: '2026-02-28',
      );

      final session = q.getActiveStandupSession('group-1', '2026-02-28');
      expect(session, isNotNull);
      expect(session!.status, equals(StandupSessionStatus.active));
    });

    test('updateStandupSession modifies status', () {
      q.createStandupSession(
        signalGroupId: 'group-1',
        date: '2026-02-28',
      );
      final session = q.getActiveStandupSession('group-1', '2026-02-28')!;

      q.updateStandupSession(session.id,
          status: StandupSessionStatus.summarized);

      final updated = q.getActiveStandupSession('group-1', '2026-02-28');
      expect(updated!.status, equals(StandupSessionStatus.summarized));
    });

    test('enforces unique constraint on (signalGroupId, date)', () {
      q.createStandupSession(
        signalGroupId: 'group-1',
        date: '2026-02-28',
      );

      expect(
        () => q.createStandupSession(
          signalGroupId: 'group-1',
          date: '2026-02-28',
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('allows same group on different dates', () {
      q.createStandupSession(
        signalGroupId: 'group-1',
        date: '2026-02-28',
      );
      q.createStandupSession(
        signalGroupId: 'group-1',
        date: '2026-03-01',
      );

      expect(q.getActiveStandupSession('group-1', '2026-02-28'), isNotNull);
      expect(q.getActiveStandupSession('group-1', '2026-03-01'), isNotNull);
    });
  });

  // -----------------------------------------------------------------------
  // Standup Responses
  // -----------------------------------------------------------------------

  group('Standup Responses', () {
    late int sessionId;

    setUp(() {
      q.createStandupSession(
        signalGroupId: 'group-1',
        date: '2026-02-28',
      );
      sessionId = q.getActiveStandupSession('group-1', '2026-02-28')!.id;
    });

    test('upsertStandupResponse inserts new response', () {
      q.upsertStandupResponse(
        sessionId: sessionId,
        signalUuid: 'uuid-1',
        yesterday: 'Fixed bugs',
        today: 'Writing tests',
      );

      final responses = q.getStandupResponses(sessionId);
      expect(responses, hasLength(1));
      expect(responses.first.yesterday, equals('Fixed bugs'));
      expect(responses.first.today, equals('Writing tests'));
    });

    test('upsertStandupResponse updates on conflict', () {
      q.upsertStandupResponse(
        sessionId: sessionId,
        signalUuid: 'uuid-1',
        yesterday: 'Old update',
        today: 'Old plan',
      );

      q.upsertStandupResponse(
        sessionId: sessionId,
        signalUuid: 'uuid-1',
        yesterday: 'New update',
        today: 'New plan',
        blockers: 'Blocked on review',
      );

      final responses = q.getStandupResponses(sessionId);
      expect(responses, hasLength(1));
      expect(responses.first.yesterday, equals('New update'));
      expect(responses.first.blockers, equals('Blocked on review'));
    });

    test('getStandupResponses returns all responses for a session', () {
      q.upsertStandupResponse(
        sessionId: sessionId,
        signalUuid: 'uuid-1',
        rawMessage: 'Done stuff, doing stuff',
      );
      q.upsertStandupResponse(
        sessionId: sessionId,
        signalUuid: 'uuid-2',
        rawMessage: 'All good',
      );

      expect(q.getStandupResponses(sessionId), hasLength(2));
    });

    test('getStandupResponses returns empty list for unknown session', () {
      expect(q.getStandupResponses(9999), isEmpty);
    });
  });

  // -----------------------------------------------------------------------
  // Calendar Reminders
  // -----------------------------------------------------------------------

  group('Calendar Reminders', () {
    test('hasCalendarReminderBeenSent returns false when none exists', () {
      expect(
        q.hasCalendarReminderBeenSent(
          'event-1',
          'group-1',
          CalendarReminderWindow.oneHour,
        ),
        isFalse,
      );
    });

    test('recordCalendarReminder then hasCalendarReminderBeenSent', () {
      q.recordCalendarReminder(
        'event-1',
        'group-1',
        CalendarReminderWindow.oneHour,
      );

      expect(
        q.hasCalendarReminderBeenSent(
          'event-1',
          'group-1',
          CalendarReminderWindow.oneHour,
        ),
        isTrue,
      );
    });

    test('different reminder windows are independent', () {
      q.recordCalendarReminder(
        'event-1',
        'group-1',
        CalendarReminderWindow.twentyFourHours,
      );

      expect(
        q.hasCalendarReminderBeenSent(
          'event-1',
          'group-1',
          CalendarReminderWindow.twentyFourHours,
        ),
        isTrue,
      );
      expect(
        q.hasCalendarReminderBeenSent(
          'event-1',
          'group-1',
          CalendarReminderWindow.oneHour,
        ),
        isFalse,
      );
    });

    test('recordCalendarReminder is idempotent (no duplicate error)', () {
      q.recordCalendarReminder(
        'event-1',
        'group-1',
        CalendarReminderWindow.fifteenMinutes,
      );
      // Should not throw.
      q.recordCalendarReminder(
        'event-1',
        'group-1',
        CalendarReminderWindow.fifteenMinutes,
      );
    });

    test('cleanOldCalendarReminders removes old entries', () {
      // Insert an old reminder directly.
      db.handle.execute(
        'INSERT INTO calendar_reminders '
        '(event_uid, signal_group_id, reminder_window, sent_at) '
        "VALUES ('event-old', 'group-1', '1h', datetime('now', '-30 days'))",
      );
      q.recordCalendarReminder(
        'event-new',
        'group-1',
        CalendarReminderWindow.oneHour,
      );

      q.cleanOldCalendarReminders(olderThanDays: 7);

      expect(
        q.hasCalendarReminderBeenSent(
          'event-old',
          'group-1',
          CalendarReminderWindow.oneHour,
        ),
        isFalse,
      );
      expect(
        q.hasCalendarReminderBeenSent(
          'event-new',
          'group-1',
          CalendarReminderWindow.oneHour,
        ),
        isTrue,
      );
    });
  });
}
