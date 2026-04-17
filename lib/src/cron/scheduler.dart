/// Timer-based scheduler for recurring tasks.
///
/// Currently handles:
/// - **Standup prompts**: Sends a prompt message at the configured hour.
/// - **Standup summaries**: Composes and sends a summary at the configured
///   summary hour, including all responses collected during the day.
/// - **Proactive nudges**: At the configured nudge hour, asks the agent to
///   check Kan for overdue/stale cards and nudge the team. Daily dedup
///   via `bot_metadata`.
/// - **Task radar**: Autonomous background scans at jittered intervals
///   (3–6 hours) during waking hours. Synthesizes across all data sources
///   with full tool access.
/// - **Nightly dreams**: Triggers the dream cycle for workspace-linked
///   groups during the 3 AM cleanup window.
/// - **Data cleanup**: Removes old reminders and calendar reminder records.
///
/// The scheduler checks all standup configs every minute and fires actions
/// when the current time matches a configured hour. Idempotent — duplicate
/// sends are prevented by checking for existing standup sessions.
library;

import 'dart:async';
import 'dart:math';
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
///
/// System-initiated: tools are disabled for fast single-round responses.
typedef ComposeViaAgentFn = Future<String> Function(
  String groupId,
  String taskDescription,
);

/// Like [ComposeViaAgentFn] but with full tool access and rich context
/// (memories, events, repos). Used by the task radar for cross-source synthesis.
typedef ComposeWithToolsFn = Future<String> Function(
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
    this.composeWithTools,
    this.triggerDream,
    this.backfill,
    this.consolidator,
    Random? random,
  }) : _random = random ?? Random();

  final Queries queries;
  final SendMessageFn sendMessage;

  /// Optional agent composition callback. When provided, scheduled messages
  /// are composed by Claude in-character. Falls back to hardcoded text on
  /// exception or when null.
  final ComposeViaAgentFn? composeViaAgent;

  /// Optional tool-enabled composition callback for the task radar.
  ///
  /// Unlike [composeViaAgent], this routes through the agent loop with full
  /// tool access and rich context (memories, events, repos) so the agent can
  /// query Kan, Outline, calendar, and memory to synthesize task suggestions.
  final ComposeWithToolsFn? composeWithTools;

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

  /// Random number generator for jittered radar intervals.
  final Random _random;

  /// Next scheduled radar scan time per group (UTC).
  ///
  /// Computed lazily on first tick and after each scan. Jittered between
  /// [_radarMinIntervalHours] and [_radarMaxIntervalHours] to avoid
  /// synchronized spikes across groups.
  final Map<String, DateTime> _nextRadarScan = {};

  /// Minimum hours between radar scans for a single group.
  static const _radarMinIntervalHours = 3;

  /// Maximum hours between radar scans for a single group.
  static const _radarMaxIntervalHours = 6;

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
        final session = queries.getActiveStandupSession(config.groupId, today);
        if (session != null && session.status == StandupSessionStatus.active) {
          final responses = queries.getStandupResponses(session.id);
          if (responses.isNotEmpty) {
            await _sendStandupSummary(config, session, responses);
          }
        }
      }

      // Check if it's nudge hour — send proactive task nudges.
      final nudgeHour = config.nudgeHour;
      if (nudgeHour != null && localNow.hour == nudgeHour) {
        await _sendProactiveNudge(config.groupId, today);
      }

      // Task radar — autonomous jittered background scans.
      if (config.radarEnabled) {
        await _maybeRunRadar(config.groupId, now, localNow);
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
        message =
            composed.isNotEmpty ? composed : _buildHardcodedSummary(responses);
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

  /// Sends a proactive nudge about overdue and stale Kan cards for one group.
  ///
  /// Asks the agent to search Kan for cards that need attention and compose
  /// an in-character nudge message. Uses `bot_metadata` for daily dedup.
  Future<void> _sendProactiveNudge(String groupId, String date) async {
    final compose = composeViaAgent;
    if (compose == null) return;

    // Daily dedup — only nudge once per group per day.
    final nudgeKey = 'nudge::$groupId::$date';
    if (queries.getMetadata(nudgeKey) != null) return;

    // Look up the workspace name for a better prompt.
    final workspace = queries.getWorkspaceLink(groupId);
    final workspaceContext = workspace != null
        ? ' The linked workspace is "${workspace.workspaceName}".'
        : '';

    try {
      final nudge = await compose(
        groupId,
        'Check Kan for overdue cards (past their due date) and stale cards '
        '(no activity in 7+ days).$workspaceContext '
        'Use get_chat_config to find the workspace if needed, then '
        'search Kan for cards that need attention. If you find any, '
        'compose a brief, friendly nudge message for the team — mention '
        'specific cards by name, note how overdue they are, and ask if '
        'there are blockers. If nothing needs attention, return an empty '
        'response. Be helpful, not nagging.',
      );
      if (nudge.isNotEmpty) {
        await sendMessage(groupId, nudge);
      }
      // Mark as nudged regardless of whether we sent — avoids retrying
      // when there's genuinely nothing to nudge about.
      queries.setMetadata(nudgeKey, DateTime.now().toUtc().toIso8601String());
    } on Exception catch (e) {
      developer.log(
        'Proactive nudge failed for $groupId: $e',
        name: 'Scheduler',
        level: 900,
      );
    }
  }

  /// Returns a jittered duration between [_radarMinIntervalHours] and
  /// [_radarMaxIntervalHours].
  Duration _randomRadarInterval() {
    final hours = _radarMinIntervalHours +
        _random.nextDouble() *
            (_radarMaxIntervalHours - _radarMinIntervalHours);
    return Duration(minutes: (hours * 60).round());
  }

  /// Checks whether it's time to run the task radar for [groupId].
  ///
  /// Uses jittered intervals (3–6 hours) instead of a fixed hour. Respects
  /// quiet hours (7 AM – 10 PM local) and a minimum-interval frequency cap
  /// persisted in `bot_metadata` to survive restarts.
  Future<void> _maybeRunRadar(
    String groupId,
    DateTime now,
    DateTime localNow,
  ) async {
    // Only ruminate during waking hours (7 AM – 10 PM local).
    if (localNow.hour < 7 || localNow.hour >= 22) return;

    // Initialize next-scan time if not set (first tick after startup).
    // Stagger 30–90 minutes out so groups don't all fire at once.
    if (!_nextRadarScan.containsKey(groupId)) {
      _nextRadarScan[groupId] = now.add(
        Duration(minutes: 30 + _random.nextInt(60)),
      );
      return;
    }

    // Not time yet.
    if (now.isBefore(_nextRadarScan[groupId]!)) return;

    // Frequency cap: check metadata for last scan timestamp (survives restarts).
    final lastKey = 'task_radar_last::$groupId';
    final lastScanStr = queries.getMetadata(lastKey);
    if (lastScanStr != null) {
      final lastScan = DateTime.tryParse(lastScanStr);
      if (lastScan != null &&
          now.difference(lastScan).inHours < _radarMinIntervalHours) {
        // Too soon — reschedule and skip.
        _nextRadarScan[groupId] = now.add(_randomRadarInterval());
        return;
      }
    }

    // Schedule the next scan regardless of outcome.
    _nextRadarScan[groupId] = now.add(_randomRadarInterval());

    // Run the scan.
    await _sendTaskRadar(groupId, now);
  }

  /// Runs the task radar — a proactive scan across all data sources to
  /// suggest tasks the team should consider.
  ///
  /// Unlike [_sendProactiveNudge] which only checks for overdue cards,
  /// the task radar has full tool access and synthesizes across Kan, Outline,
  /// calendar, team profiles, standup patterns, and conversation memory.
  Future<void> _sendTaskRadar(String groupId, DateTime now) async {
    final compose = composeWithTools;
    if (compose == null) return;

    // Look up the workspace name for context.
    final workspace = queries.getWorkspaceLink(groupId);
    final workspaceContext = workspace != null
        ? ' The linked workspace is "${workspace.workspaceName}".'
        : '';

    try {
      final suggestion = await compose(
        groupId,
        'You have time to think about what the team should work on. Look '
        'around — check the board, recent standups, upcoming events, your '
        'knowledge base, and what you remember from conversations. Connect '
        'dots across these sources.$workspaceContext\n\n'
        'Some questions to consider (not a checklist — follow what\'s '
        'interesting):\n'
        '- Is anyone working on something that doesn\'t have a card yet?\n'
        '- Are there upcoming events that need prep work?\n'
        '- Is there knowledge in Outline that suggests untracked work?\n'
        '- Are there patterns in recent standups (repeated blockers, '
        'mentions of things people want to do)?\n'
        '- Who seems underloaded or has expressed interest in something '
        'unassigned?\n\n'
        'If something stands out, suggest 1-3 specific tasks. Name who '
        'might be a good fit and why. If nothing stands out, say so '
        'briefly — don\'t manufacture work.\n\n'
        'Be specific and grounded — reference actual cards, docs, events, '
        'and people by name.',
      );
      if (suggestion.isNotEmpty) {
        await sendMessage(groupId, suggestion);
      }
      // Record scan timestamp for frequency cap (survives restarts).
      final lastKey = 'task_radar_last::$groupId';
      queries.setMetadata(lastKey, now.toUtc().toIso8601String());
    } on Exception catch (e) {
      developer.log(
        'Task radar failed for $groupId: $e',
        name: 'Scheduler',
        level: 900,
      );
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
