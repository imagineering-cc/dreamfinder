import 'package:dreamfinder/src/cron/scheduler.dart';
import 'package:dreamfinder/src/db/database.dart';
import 'package:dreamfinder/src/db/queries.dart';
import 'package:dreamfinder/src/db/schema.dart';
import 'package:dreamfinder/src/memory/embedding_backfill.dart';
import 'package:dreamfinder/src/memory/memory_consolidator.dart';
import 'package:test/test.dart';

void main() {
  late BotDatabase db;
  late Queries queries;

  setUp(() {
    db = BotDatabase.inMemory();
    queries = Queries(db);
  });

  tearDown(() {
    db.close();
  });

  group('Scheduler', () {
    test('can be created and stopped without error', () {
      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {},
      );
      scheduler.start();
      scheduler.stop();
    });

    test('does not throw when no standup configs exist', () async {
      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {},
      );

      // Manually trigger tick — no configs means no work.
      await scheduler.tick(DateTime(2026, 3, 2, 9, 0));
    });
  });

  group('Scheduler standup prompts', () {
    test('sends prompt at configured hour', () async {
      queries.upsertStandupConfig(
        groupId: 'group-1',
        promptHour: 9,
      );

      final sentMessages = <MapEntry<String, String>>[];
      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {
          sentMessages.add(MapEntry(groupId, message));
        },
      );

      // 9:00 AM — prompt hour.
      await scheduler.tick(DateTime(2026, 3, 2, 9, 0));

      expect(sentMessages, hasLength(1));
      expect(sentMessages.first.key, equals('group-1'));
      expect(sentMessages.first.value, contains('standup'));
    });

    test('does not send prompt if already sent today', () async {
      queries.upsertStandupConfig(
        groupId: 'group-1',
        promptHour: 9,
      );

      final sentMessages = <MapEntry<String, String>>[];
      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {
          sentMessages.add(MapEntry(groupId, message));
        },
      );

      // First tick creates the session and sends the prompt.
      await scheduler.tick(DateTime(2026, 3, 2, 9, 0));
      expect(sentMessages, hasLength(1));

      // Second tick at same hour — should not re-send.
      await scheduler.tick(DateTime(2026, 3, 2, 9, 30));
      expect(sentMessages, hasLength(1));
    });

    test('skips disabled groups', () async {
      queries.upsertStandupConfig(
        groupId: 'group-1',
        enabled: false,
      );

      final sentMessages = <MapEntry<String, String>>[];
      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {
          sentMessages.add(MapEntry(groupId, message));
        },
      );

      await scheduler.tick(DateTime(2026, 3, 2, 9, 0));
      expect(sentMessages, isEmpty);
    });

    test('skips weekends when configured', () async {
      queries.upsertStandupConfig(
        groupId: 'group-1',
        promptHour: 9,
        skipWeekends: true,
      );

      final sentMessages = <MapEntry<String, String>>[];
      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {
          sentMessages.add(MapEntry(groupId, message));
        },
      );

      // Saturday March 7, 2026.
      await scheduler.tick(DateTime(2026, 3, 7, 9, 0));
      expect(sentMessages, isEmpty);
    });
  });

  group('Scheduler agent composition', () {
    test('uses composeViaAgent when provided', () async {
      queries.upsertStandupConfig(
        groupId: 'group-1',
        promptHour: 9,
      );

      final sentMessages = <MapEntry<String, String>>[];
      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {
          sentMessages.add(MapEntry(groupId, message));
        },
        composeViaAgent: (groupId, taskDescription) async {
          return 'Rise and shine, team! What are you working on today?';
        },
      );

      await scheduler.tick(DateTime(2026, 3, 2, 9, 0));

      expect(sentMessages, hasLength(1));
      expect(sentMessages.first.value, equals(
        'Rise and shine, team! What are you working on today?',
      ));
    });

    test('falls back to hardcoded message when composeViaAgent throws',
        () async {
      queries.upsertStandupConfig(
        groupId: 'group-1',
        promptHour: 9,
      );

      final sentMessages = <MapEntry<String, String>>[];
      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {
          sentMessages.add(MapEntry(groupId, message));
        },
        composeViaAgent: (groupId, taskDescription) async {
          throw Exception('Claude API is down');
        },
      );

      await scheduler.tick(DateTime(2026, 3, 2, 9, 0));

      expect(sentMessages, hasLength(1));
      expect(sentMessages.first.value, equals(Scheduler.hardcodedStandupPrompt));

      // Session should still be created despite the agent failure.
      final session = queries.getActiveStandupSession('group-1', '2026-03-02');
      expect(session, isNotNull);
    });

    test('falls back to hardcoded message when composeViaAgent returns empty',
        () async {
      queries.upsertStandupConfig(
        groupId: 'group-1',
        promptHour: 9,
      );

      final sentMessages = <MapEntry<String, String>>[];
      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {
          sentMessages.add(MapEntry(groupId, message));
        },
        composeViaAgent: (groupId, taskDescription) async {
          return '';
        },
      );

      await scheduler.tick(DateTime(2026, 3, 2, 9, 0));

      expect(sentMessages, hasLength(1));
      expect(
          sentMessages.first.value, equals(Scheduler.hardcodedStandupPrompt));
    });

    test('sends hardcoded message when composeViaAgent is null', () async {
      queries.upsertStandupConfig(
        groupId: 'group-1',
        promptHour: 9,
      );

      final sentMessages = <MapEntry<String, String>>[];
      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {
          sentMessages.add(MapEntry(groupId, message));
        },
        // No composeViaAgent provided.
      );

      await scheduler.tick(DateTime(2026, 3, 2, 9, 0));

      expect(sentMessages, hasLength(1));
      expect(sentMessages.first.value, equals(Scheduler.hardcodedStandupPrompt));
    });
  });

  group('Scheduler old data cleanup', () {
    test('cleanOldData removes old reminders and calendar reminders', () {
      // Insert an old reminder.
      queries.upsertReminder('card-old', 'group-1');
      // Force the reminder timestamp to be 30 days ago.
      db.handle.execute(
        "UPDATE sent_reminders SET last_reminder_at = datetime('now', '-30 days')",
      );

      // Insert an old calendar reminder.
      queries.recordCalendarReminder('event-old', 'group-1',
          CalendarReminderWindow.twentyFourHours);
      db.handle.execute(
        "UPDATE calendar_reminders SET sent_at = datetime('now', '-30 days')",
      );

      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {},
      );
      scheduler.cleanOldData();

      expect(queries.getLastReminder('card-old', 'group-1'), isNull);
      expect(
        queries.hasCalendarReminderBeenSent(
          'event-old', 'group-1', CalendarReminderWindow.twentyFourHours),
        isFalse,
      );
    });

    test('tick triggers cleanup once per day after 3 AM', () async {
      // Insert old data to verify cleanup runs.
      queries.upsertReminder('card-old', 'group-1');
      db.handle.execute(
        "UPDATE sent_reminders SET last_reminder_at = datetime('now', '-30 days')",
      );

      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {},
      );

      // Tick at 3:15 AM — should trigger cleanup.
      await scheduler.tick(DateTime(2026, 3, 2, 3, 15));
      expect(queries.getLastReminder('card-old', 'group-1'), isNull);

      // Insert new old data.
      queries.upsertReminder('card-old-2', 'group-1');
      db.handle.execute(
        "UPDATE sent_reminders SET last_reminder_at = datetime('now', '-30 days') "
        "WHERE card_public_id = 'card-old-2'",
      );

      // Tick again same day at 4 AM — should NOT re-run cleanup.
      await scheduler.tick(DateTime(2026, 3, 2, 4, 0));
      expect(queries.getLastReminder('card-old-2', 'group-1'), isNotNull);

      // Tick next day at 3:00 AM — should trigger cleanup again.
      await scheduler.tick(DateTime(2026, 3, 3, 3, 0));
      expect(queries.getLastReminder('card-old-2', 'group-1'), isNull);
    });

    test('tick does not trigger cleanup before 3 AM', () async {
      queries.upsertReminder('card-old', 'group-1');
      db.handle.execute(
        "UPDATE sent_reminders SET last_reminder_at = datetime('now', '-30 days')",
      );

      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {},
      );

      // Tick at 2:59 AM — too early, no cleanup.
      await scheduler.tick(DateTime(2026, 3, 2, 2, 59));
      expect(queries.getLastReminder('card-old', 'group-1'), isNotNull);
    });
  });

  group('Scheduler memory consolidation', () {
    test('calls consolidate during daily cleanup window', () async {
      var consolidateCalled = false;
      final consolidator = FakeMemoryConsolidator(
        onConsolidate: () => consolidateCalled = true,
      );

      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {},
        consolidator: consolidator,
      );

      // Tick at 3:15 AM — cleanup window.
      await scheduler.tick(DateTime(2026, 3, 2, 3, 15));

      expect(consolidateCalled, isTrue);
    });

    test('skips consolidation when consolidator is null', () async {
      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {},
        // No consolidator.
      );

      // Should not throw.
      await scheduler.tick(DateTime(2026, 3, 2, 3, 15));
    });

    test('does not call consolidate before 3 AM', () async {
      var consolidateCalled = false;
      final consolidator = FakeMemoryConsolidator(
        onConsolidate: () => consolidateCalled = true,
      );

      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {},
        consolidator: consolidator,
      );

      await scheduler.tick(DateTime(2026, 3, 2, 2, 59));

      expect(consolidateCalled, isFalse);
    });
  });

  group('Scheduler embedding backfill', () {
    test('runs backfill before consolidation in daily window', () async {
      final callOrder = <String>[];
      final backfill = FakeEmbeddingBackfill(
        onBackfill: () => callOrder.add('backfill'),
      );
      final consolidator = FakeMemoryConsolidator(
        onConsolidate: () => callOrder.add('consolidate'),
      );

      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {},
        backfill: backfill,
        consolidator: consolidator,
      );

      await scheduler.tick(DateTime(2026, 3, 2, 3, 15));

      expect(callOrder, equals(['backfill', 'consolidate']));
    });

    test('works without backfill when null', () async {
      var consolidateCalled = false;
      final consolidator = FakeMemoryConsolidator(
        onConsolidate: () => consolidateCalled = true,
      );

      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {},
        // No backfill provided.
        consolidator: consolidator,
      );

      await scheduler.tick(DateTime(2026, 3, 2, 3, 15));

      // Consolidator should still run.
      expect(consolidateCalled, isTrue);
    });
  });

  group('Scheduler standup summary', () {
    test('sends summary at configured summary_hour via agent', () async {
      queries.upsertStandupConfig(
        groupId: 'group-1',
        promptHour: 9,
        summaryHour: 17,
      );

      // Simulate a morning: prompt sent, session created, responses recorded.
      await Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {},
      ).tick(DateTime(2026, 3, 2, 9, 0));

      final session =
          queries.getActiveStandupSession('group-1', '2026-03-02');
      queries.upsertStandupResponse(
        sessionId: session!.id,
        userId: 'user-1',
        displayName: 'Alice',
        yesterday: 'Fixed bug #42',
        today: 'Working on feature X',
        blockers: null,
      );

      final composedTasks = <MapEntry<String, String>>[];
      final sentMessages = <MapEntry<String, String>>[];
      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {
          sentMessages.add(MapEntry(groupId, message));
        },
        composeViaAgent: (groupId, taskDescription) async {
          composedTasks.add(MapEntry(groupId, taskDescription));
          return 'Here is the standup summary!';
        },
      );

      // 5 PM — summary hour.
      await scheduler.tick(DateTime(2026, 3, 2, 17, 0));

      expect(composedTasks, hasLength(1));
      expect(composedTasks.first.key, 'group-1');
      expect(composedTasks.first.value, contains('summary'));
      expect(sentMessages, hasLength(1));
      expect(sentMessages.first.value, 'Here is the standup summary!');

      // Session should be marked as summarized.
      final updated =
          queries.getActiveStandupSession('group-1', '2026-03-02');
      expect(updated!.status, StandupSessionStatus.summarized);
    });

    test('does not send summary if session already summarized', () async {
      queries.upsertStandupConfig(
        groupId: 'group-1',
        promptHour: 9,
        summaryHour: 17,
      );

      // Create session and mark it as already summarized.
      queries.createStandupSession(groupId: 'group-1', date: '2026-03-02');
      final session =
          queries.getActiveStandupSession('group-1', '2026-03-02');
      queries.updateStandupSession(
        session!.id,
        status: StandupSessionStatus.summarized,
      );

      var composeCalled = false;
      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {},
        composeViaAgent: (groupId, taskDescription) async {
          composeCalled = true;
          return '';
        },
      );

      await scheduler.tick(DateTime(2026, 3, 2, 17, 0));
      expect(composeCalled, isFalse);
    });

    test('does not send summary if no session exists today', () async {
      queries.upsertStandupConfig(
        groupId: 'group-1',
        promptHour: 9,
        summaryHour: 17,
      );

      var composeCalled = false;
      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {},
        composeViaAgent: (groupId, taskDescription) async {
          composeCalled = true;
          return '';
        },
      );

      // 5 PM but no prompt was sent this morning — no session to summarize.
      await scheduler.tick(DateTime(2026, 3, 2, 17, 0));
      expect(composeCalled, isFalse);
    });

    test('does not send summary if no responses recorded', () async {
      queries.upsertStandupConfig(
        groupId: 'group-1',
        promptHour: 9,
        summaryHour: 17,
      );

      // Session exists (prompt was sent) but nobody responded.
      queries.createStandupSession(groupId: 'group-1', date: '2026-03-02');

      var composeCalled = false;
      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {},
        composeViaAgent: (groupId, taskDescription) async {
          composeCalled = true;
          return '';
        },
      );

      await scheduler.tick(DateTime(2026, 3, 2, 17, 0));
      expect(composeCalled, isFalse);
    });

    test('falls back gracefully when composeViaAgent is null', () async {
      queries.upsertStandupConfig(
        groupId: 'group-1',
        promptHour: 9,
        summaryHour: 17,
      );

      queries.createStandupSession(groupId: 'group-1', date: '2026-03-02');
      final session =
          queries.getActiveStandupSession('group-1', '2026-03-02');
      queries.upsertStandupResponse(
        sessionId: session!.id,
        userId: 'user-1',
        displayName: 'Alice',
        yesterday: 'Did stuff',
        today: 'More stuff',
      );

      final sentMessages = <String>[];
      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {
          sentMessages.add(message);
        },
        // No composeViaAgent.
      );

      await scheduler.tick(DateTime(2026, 3, 2, 17, 0));

      // Should send a hardcoded summary with the response data.
      expect(sentMessages, hasLength(1));
      expect(sentMessages.first, contains('Alice'));
      expect(sentMessages.first, contains('Did stuff'));

      // Session should still be marked summarized.
      final updated =
          queries.getActiveStandupSession('group-1', '2026-03-02');
      expect(updated!.status, StandupSessionStatus.summarized);
    });

    test('includes response data in agent task description', () async {
      queries.upsertStandupConfig(
        groupId: 'group-1',
        promptHour: 9,
        summaryHour: 17,
      );

      queries.createStandupSession(groupId: 'group-1', date: '2026-03-02');
      final session =
          queries.getActiveStandupSession('group-1', '2026-03-02');
      queries.upsertStandupResponse(
        sessionId: session!.id,
        userId: 'user-1',
        displayName: 'Alice',
        yesterday: 'Fixed bug #42',
        today: 'Feature X',
        blockers: 'Waiting on API access',
      );
      queries.upsertStandupResponse(
        sessionId: session.id,
        userId: 'user-2',
        displayName: 'Bob',
        yesterday: 'Code review',
        today: 'Deploy v2',
      );

      String? taskDesc;
      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {},
        composeViaAgent: (groupId, taskDescription) async {
          taskDesc = taskDescription;
          return 'Summary!';
        },
      );

      await scheduler.tick(DateTime(2026, 3, 2, 17, 0));

      expect(taskDesc, contains('Alice'));
      expect(taskDesc, contains('Bob'));
      expect(taskDesc, contains('Fixed bug #42'));
      expect(taskDesc, contains('Waiting on API access'));
    });
  });

  group('Scheduler Repo Radar digest', () {
    test('sends digest via agent for tracked repos during cleanup', () async {
      queries.upsertTrackedRepo(
        repo: 'dart-lang/sdk',
        reason: 'Core SDK',
        sourceChatId: 'room-1',
      );
      queries.upsertTrackedRepo(
        repo: 'flutter/flutter',
        reason: 'Mobile framework',
        sourceChatId: 'room-1',
      );

      final composedTasks = <MapEntry<String, String>>[];
      final sentMessages = <MapEntry<String, String>>[];

      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {
          sentMessages.add(MapEntry(groupId, message));
        },
        composeViaAgent: (groupId, taskDescription) async {
          composedTasks.add(MapEntry(groupId, taskDescription));
          return 'Here is your repo radar digest!';
        },
      );

      // Tick at 3 AM to trigger daily cleanup + digest.
      await scheduler.tick(DateTime(2026, 3, 2, 3, 15));

      expect(composedTasks, hasLength(1));
      expect(composedTasks.first.key, 'room-1');
      expect(composedTasks.first.value, contains('dart-lang/sdk'));
      expect(composedTasks.first.value, contains('flutter/flutter'));
      expect(sentMessages, hasLength(1));
      expect(sentMessages.first.value, 'Here is your repo radar digest!');
    });

    test('groups digest by source chat', () async {
      queries.upsertTrackedRepo(
        repo: 'dart-lang/sdk',
        reason: 'SDK',
        sourceChatId: 'room-1',
      );
      queries.upsertTrackedRepo(
        repo: 'flutter/flutter',
        reason: 'Flutter',
        sourceChatId: 'room-2',
      );

      final composedChats = <String>[];

      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {},
        composeViaAgent: (groupId, taskDescription) async {
          composedChats.add(groupId);
          return 'Digest for $groupId';
        },
      );

      await scheduler.tick(DateTime(2026, 3, 2, 3, 15));

      expect(composedChats, containsAll(['room-1', 'room-2']));
    });

    test('skips digest when no tracked repos', () async {
      var composeCalled = false;

      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {},
        composeViaAgent: (groupId, taskDescription) async {
          composeCalled = true;
          return '';
        },
      );

      await scheduler.tick(DateTime(2026, 3, 2, 3, 15));

      expect(composeCalled, isFalse);
    });

    test('skips digest when composeViaAgent is null', () async {
      queries.upsertTrackedRepo(
        repo: 'dart-lang/sdk',
        reason: 'SDK',
        sourceChatId: 'room-1',
      );

      final sentMessages = <String>[];

      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {
          sentMessages.add(message);
        },
        // No composeViaAgent — digest should be skipped.
      );

      await scheduler.tick(DateTime(2026, 3, 2, 3, 15));

      // Only cleanup runs, no digest message sent.
      expect(sentMessages, isEmpty);
    });
  });

  group('Scheduler nightly dream trigger', () {
    test('triggers dream for each workspace-linked group during cleanup',
        () async {
      // Create workspace links for two groups.
      queries.createWorkspaceLink(
        groupId: 'room-1',
        workspacePublicId: 'ws-1',
        workspaceName: 'Imagineering',
        createdByUuid: 'user-1',
      );
      queries.createWorkspaceLink(
        groupId: 'room-2',
        workspacePublicId: 'ws-2',
        workspaceName: 'Ops',
        createdByUuid: 'user-1',
      );

      final triggeredGroups = <String>[];
      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {},
        triggerDream: ({
          required String groupId,
          required String triggeredByUuid,
          required String date,
        }) {
          triggeredGroups.add(groupId);
          return true;
        },
      );

      // Tick at 3:15 AM — cleanup window.
      await scheduler.tick(DateTime(2026, 3, 2, 3, 15));

      expect(triggeredGroups, containsAll(['room-1', 'room-2']));
    });

    test('passes scheduler as triggeredByUuid', () async {
      queries.createWorkspaceLink(
        groupId: 'room-1',
        workspacePublicId: 'ws-1',
        workspaceName: 'Test',
        createdByUuid: 'user-1',
      );

      String? capturedTriggeredBy;
      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {},
        triggerDream: ({
          required String groupId,
          required String triggeredByUuid,
          required String date,
        }) {
          capturedTriggeredBy = triggeredByUuid;
          return true;
        },
      );

      await scheduler.tick(DateTime(2026, 3, 2, 3, 15));

      expect(capturedTriggeredBy, equals('scheduler'));
    });

    test('does not trigger dream before 3 AM', () async {
      queries.createWorkspaceLink(
        groupId: 'room-1',
        workspacePublicId: 'ws-1',
        workspaceName: 'Test',
        createdByUuid: 'user-1',
      );

      var triggered = false;
      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {},
        triggerDream: ({
          required String groupId,
          required String triggeredByUuid,
          required String date,
        }) {
          triggered = true;
          return true;
        },
      );

      // 2:59 AM — too early.
      await scheduler.tick(DateTime(2026, 3, 2, 2, 59));

      expect(triggered, isFalse);
    });

    test('does not error when triggerDream is null', () async {
      queries.createWorkspaceLink(
        groupId: 'room-1',
        workspacePublicId: 'ws-1',
        workspaceName: 'Test',
        createdByUuid: 'user-1',
      );

      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {},
        // No triggerDream provided.
      );

      // Should not throw.
      await scheduler.tick(DateTime(2026, 3, 2, 3, 15));
    });

    test('does not trigger when no workspace links exist', () async {
      var triggered = false;
      final scheduler = Scheduler(
        queries: queries,
        sendMessage: (groupId, message) async {},
        triggerDream: ({
          required String groupId,
          required String triggeredByUuid,
          required String date,
        }) {
          triggered = true;
          return true;
        },
      );

      await scheduler.tick(DateTime(2026, 3, 2, 3, 15));

      expect(triggered, isFalse);
    });
  });
}

/// Fake backfill for scheduler tests.
class FakeEmbeddingBackfill implements EmbeddingBackfill {
  FakeEmbeddingBackfill({this.onBackfill});

  final void Function()? onBackfill;

  @override
  int get batchLimit => 50;

  @override
  Future<int> backfill() async {
    onBackfill?.call();
    return 0;
  }
}

/// Fake consolidator for scheduler tests.
class FakeMemoryConsolidator implements MemoryConsolidator {
  FakeMemoryConsolidator({this.onConsolidate});

  final void Function()? onConsolidate;

  @override
  int get batchSize => 20;

  @override
  int get minAgeHours => 48;

  @override
  Future<void> consolidate() async {
    onConsolidate?.call();
  }
}
