/// Timer-based scheduler for recurring tasks.
///
/// Currently handles:
/// - **Standup prompts**: Sends a prompt message at the configured hour.
/// - **Standup summaries**: Composes and sends a summary at the configured
///   summary hour, including all responses collected during the day.
/// - **Data cleanup**: Removes old reminders and calendar reminder records.
///
/// The scheduler checks all standup configs every minute and fires actions
/// when the current time matches a configured hour. Idempotent — duplicate
/// sends are prevented by checking for existing standup sessions.
library;

import 'dart:async';
import 'dart:developer' as developer;

import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../db/queries.dart';
import '../db/schema.dart';
import '../memory/embedding_backfill.dart';
import '../memory/memory_consolidator.dart';

export '../db/schema.dart' show CalendarReminderWindow;

/// Callback for sending a message to a group chat.
typedef SendMessageFn = Future<void> Function(String groupId, String message);

/// Callback that routes a scheduled task through the agent loop so Claude
/// composes the message in-character and it lands in conversation history.
typedef ComposeViaAgentFn = Future<String> Function(
  String groupId,
  String taskDescription,
);

/// Callback to trigger a dream cycle for a group.
///
/// Returns `true` if the dream was successfully triggered.
typedef TriggerDreamFn = bool Function({
  required String groupId,
  required String triggeredByUuid,
  required String date,
});

/// Periodic scheduler for standup prompts and data cleanup.
class Scheduler {
  Scheduler({
    required this.queries,
    required this.sendMessage,
    this.composeViaAgent,
    this.triggerDream,
    this.backfill,
    this.consolidator,
  });

  final Queries queries;
  final SendMessageFn sendMessage;

  /// Optional agent composition callback. When provided, scheduled messages
  /// are composed by Claude in-character. Falls back to hardcoded text on
  /// exception or when null.
  final ComposeViaAgentFn? composeViaAgent;

  /// Optional dream trigger callback. When provided, triggers a dream cycle
  /// for each workspace-linked group during the nightly cleanup window.
  final TriggerDreamFn? triggerDream;

  /// Optional embedding backfill. When provided, retries null-embedding
  /// records before consolidation in the daily cleanup window.
  final EmbeddingBackfill? backfill;

  /// Optional memory consolidator. When provided, runs during the daily
  /// cleanup window to summarize old conversation embeddings.
  final MemoryConsolidator? consolidator;
  Timer? _timer;

  /// Tracks the last date (YYYY-MM-DD) that data cleanup ran, to ensure
  /// it fires exactly once per day regardless of timer drift.
  String? _lastCleanupDate;

  /// Starts the scheduler, ticking every 60 seconds.
  void start() {
    _ensureTimeZonesInitialized();
    _timer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => tick(DateTime.now()),
    );
  }

  static bool _timeZonesInitialized = false;

  static void _ensureTimeZonesInitialized() {
    if (!_timeZonesInitialized) {
      tzdata.initializeTimeZones();
      _timeZonesInitialized = true;
    }
  }

  /// Stops the scheduler.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Runs one scheduler cycle for the given [now] time.
  ///
  /// Public so tests can call it directly with a controlled timestamp.
  Future<void> tick(DateTime now) async {
    _ensureTimeZonesInitialized();
    final configs = queries.getAllStandupConfigs();
    for (final config in configs) {
      if (!config.enabled) continue;

      // Convert server time to the group's configured timezone.
      final localNow = _toLocalTime(now, config.timezone);

      // Skip weekends if configured (using local date).
      if (config.skipWeekends && _isWeekend(localNow)) continue;

      final today = _dateString(localNow);

      // Check if it's prompt hour in the local timezone.
      if (localNow.hour == config.promptHour) {
        final existingSession =
            queries.getActiveStandupSession(config.groupId, today);
        if (existingSession == null) {
          await _sendStandupPrompt(config, today);
        }
      }

      // Check if it's summary hour — send a summary of today's responses.
      if (localNow.hour == config.summaryHour) {
        final session =
            queries.getActiveStandupSession(config.groupId, today);
        if (session != null &&
            session.status == StandupSessionStatus.active) {
          final responses = queries.getStandupResponses(session.id);
          if (responses.isNotEmpty) {
            await _sendStandupSummary(config, session, responses);
          }
        }
      }
    }

    // Run data cleanup once per day after 3 AM. Uses a date guard instead
    // of exact minute matching so timer drift or restarts can't skip a day.
    final todayStr = _dateString(now);
    if (now.hour >= 3 && _lastCleanupDate != todayStr) {
      _lastCleanupDate = todayStr;
      cleanOldData();
      await backfill?.backfill();
      await consolidator?.consolidate();
      await _sendRepoRadarDigest();
      await _sendProactiveNudges();
      _triggerNightlyDreams(todayStr);
    }
  }

  /// The hardcoded standup prompt used when agent composition is unavailable.
  static const hardcodedStandupPrompt =
      "Good morning! Time for today's standup.\n\n"
      'Please share:\n'
      '1. What did you work on yesterday?\n'
      '2. What are you working on today?\n'
      '3. Any blockers?\n\n'
      'Just reply naturally — I\'ll record your update.';

  /// Sends the standup prompt message and creates the session record.
  ///
  /// Tries to compose the message via the agent loop so it lands in
  /// conversation history and is in-character. Falls back to
  /// [hardcodedStandupPrompt] if the agent is unavailable or throws.
  Future<void> _sendStandupPrompt(
    StandupConfigRecord config,
    String date,
  ) async {
    var message = hardcodedStandupPrompt;

    final compose = composeViaAgent;
    if (compose != null) {
      try {
        final composed = await compose(
          config.groupId,
          'Send a standup prompt. Ask the team what they worked on yesterday, '
              "what they're working on today, and if they have any blockers. "
              "Tell them to reply naturally and you'll record their update.",
        );
        if (composed.isNotEmpty) {
          message = composed;
        }
      } on Exception catch (e) {
        developer.log(
          'Agent composition failed for ${config.groupId}, '
              'using hardcoded fallback: $e',
          name: 'Scheduler',
          level: 900,
        );
      }
    }

    await sendMessage(config.groupId, message);

    queries.createStandupSession(
      groupId: config.groupId,
      date: date,
    );
  }

  /// Builds a hardcoded standup summary from the collected responses.
  static String _buildHardcodedSummary(List<StandupResponse> responses) {
    final buffer = StringBuffer("Today's standup summary:\n");
    for (final r in responses) {
      final name = r.displayName ?? r.userId;
      buffer.writeln('\n**$name**');
      if (r.yesterday != null) buffer.writeln('- Yesterday: ${r.yesterday}');
      if (r.today != null) buffer.writeln('- Today: ${r.today}');
      if (r.blockers != null) buffer.writeln('- Blockers: ${r.blockers}');
    }
    return buffer.toString().trimRight();
  }

  /// Sends the standup summary and marks the session as summarized.
  ///
  /// Tries to compose via the agent loop so the summary is in-character.
  /// Falls back to [_buildHardcodedSummary] if the agent is unavailable.
  Future<void> _sendStandupSummary(
    StandupConfigRecord config,
    StandupSession session,
    List<StandupResponse> responses,
  ) async {
    String message;

    final compose = composeViaAgent;
    if (compose != null) {
      try {
        // Build a task description that includes the raw response data
        // so the agent can compose a natural summary.
        final responseLines = StringBuffer();
        for (final r in responses) {
          final name = r.displayName ?? r.userId;
          responseLines.writeln('$name:');
          if (r.yesterday != null) {
            responseLines.writeln('  Yesterday: ${r.yesterday}');
          }
          if (r.today != null) {
            responseLines.writeln('  Today: ${r.today}');
          }
          if (r.blockers != null) {
            responseLines.writeln('  Blockers: ${r.blockers}');
          }
        }

        final composed = await compose(
          config.groupId,
          'Compose a standup summary for the team. '
              '${responses.length} people responded today. '
              'Here are their updates:\n\n$responseLines\n'
              'Summarize the updates, highlight any blockers, and note '
              'common themes. Keep it concise and useful.',
        );
        message = composed.isNotEmpty
            ? composed
            : _buildHardcodedSummary(responses);
      } on Exception catch (e) {
        developer.log(
          'Agent composition failed for standup summary in '
              '${config.groupId}: $e',
          name: 'Scheduler',
          level: 900,
        );
        message = _buildHardcodedSummary(responses);
      }
    } else {
      message = _buildHardcodedSummary(responses);
    }

    await sendMessage(config.groupId, message);

    queries.updateStandupSession(
      session.id,
      status: StandupSessionStatus.summarized,
    );
  }

  /// Sends a Repo Radar digest to each chat that has tracked repos.
  ///
  /// The digest is composed via the agent loop so it's in-character and
  /// lands in conversation history. Dreamfinder will use `crawl_repo` to
  /// refresh metadata and `list_tracked_repos` to review what's being watched.
  Future<void> _sendRepoRadarDigest() async {
    final repos = queries.getAllTrackedRepos();
    if (repos.isEmpty) return;

    // Group repos by source chat.
    final reposByChat = <String, List<String>>{};
    for (final repo in repos) {
      reposByChat.putIfAbsent(repo.sourceChatId, () => []).add(repo.repo);
    }

    final compose = composeViaAgent;
    if (compose == null) return; // Can't compose without agent.

    for (final entry in reposByChat.entries) {
      final chatId = entry.key;
      final repoNames = entry.value;

      try {
        final digest = await compose(
          chatId,
          'You have ${repoNames.length} repos on the Repo Radar: '
              '${repoNames.join(", ")}. '
              'Use crawl_repo on each to refresh their metadata, then share '
              'a brief digest of anything interesting — new releases, '
              'rising stars, notable issues. Keep it concise and useful. '
              'If nothing notable has changed, say so briefly and move on.',
        );
        if (digest.isNotEmpty) {
          await sendMessage(chatId, digest);
        }
      } on Exception catch (e) {
        developer.log(
          'Repo Radar digest failed for $chatId: $e',
          name: 'Scheduler',
          level: 900,
        );
      }
    }
  }

  /// Sends proactive nudges about overdue and stale Kan cards.
  ///
  /// For each workspace-linked group, asks the agent to search Kan for
  /// cards that need attention and compose an in-character nudge message.
  /// The agent has full MCP tool access and can query Kan directly.
  Future<void> _sendProactiveNudges() async {
    final compose = composeViaAgent;
    if (compose == null) return;

    final links = queries.getAllWorkspaceLinks();
    final groupIds = <String>{for (final link in links) link.groupId};

    for (final groupId in groupIds) {
      try {
        final nudge = await compose(
          groupId,
          'Check Kan for overdue cards (past their due date) and stale cards '
              '(no activity in 7+ days) in this workspace. If you find any '
              'that need attention, compose a brief, friendly nudge message '
              'for the team — mention specific cards by name, note how '
              'overdue they are, and ask if there are blockers. If nothing '
              'needs attention, return an empty response. '
              'Be helpful, not nagging.',
        );
        if (nudge.isNotEmpty) {
          await sendMessage(groupId, nudge);
        }
      } on Exception catch (e) {
        developer.log(
          'Proactive nudge failed for $groupId: $e',
          name: 'Scheduler',
          level: 900,
        );
      }
    }
  }

  /// Triggers a dream cycle for each workspace-linked group.
  void _triggerNightlyDreams(String date) {
    final trigger = triggerDream;
    if (trigger == null) return;

    final links = queries.getAllWorkspaceLinks();
    // Deduplicate by group ID — a group may link to multiple workspaces.
    final groupIds = <String>{for (final link in links) link.groupId};

    for (final groupId in groupIds) {
      try {
        trigger(
          groupId: groupId,
          triggeredByUuid: 'scheduler',
          date: date,
        );
      } on Exception catch (e) {
        developer.log(
          'Dream trigger failed for $groupId: $e',
          name: 'Scheduler',
          level: 900,
        );
      }
    }
  }

  /// Removes old reminders and calendar reminders from the database.
  void cleanOldData() {
    queries.cleanOldReminders(olderThanDays: 7);
    queries.cleanOldCalendarReminders(olderThanDays: 7);
  }

  /// Converts [dt] to the given IANA [timezone]. Falls back to UTC if the
  /// timezone name is invalid.
  DateTime _toLocalTime(DateTime dt, String timezone) {
    try {
      final location = tz.getLocation(timezone);
      final local = tz.TZDateTime.from(dt.toUtc(), location);
      return local;
    } on Exception {
      developer.log(
        'Unknown timezone "$timezone", falling back to UTC',
        name: 'Scheduler',
        level: 900,
      );
      return dt.toUtc();
    }
  }

  bool _isWeekend(DateTime dt) =>
      dt.weekday == DateTime.saturday || dt.weekday == DateTime.sunday;

  String _dateString(DateTime dt) =>
      '${dt.year}-${dt.month.toString().padLeft(2, '0')}-'
      '${dt.day.toString().padLeft(2, '0')}';
}

