/// Dream cycle orchestrator — autonomous nightly knowledge organization.
///
/// When triggered by a "goodnight" message, Dreamfinder enters a multi-phase
/// dream modeled after real sleep. The dream flows through sequential phases,
/// then *branches* into parallel threads — like a dream jump-cut where you
/// suddenly find yourself somewhere new without any cognitive dissonance:
///
/// ```
/// Light (N1→N2) → Deep (N2→N3) → Branch per spark (parallel) → REM (converge) → Wake
/// ```
///
/// Token usage is tracked across all phases and branches, and included in
/// the waking-up message.
library;

import 'dart:developer' as developer;

import '../agent/agent_loop.dart';
import '../agent/tool_registry.dart';
import '../db/message_repository.dart';
import '../db/queries.dart';
import '../db/schema.dart';
import 'dream_prompt.dart';

/// Default round budgets.
const defaultLightRounds = 20;
const defaultDeepRounds = 20;
const defaultBranchRounds = 15;
const defaultRemRounds = 15;

/// Callback for sending a message to a Signal group.
typedef DreamSendMessageFn = Future<void> Function(
  String groupId,
  String message,
);

/// Orchestrates the dream cycle — a multi-phase autonomous agent session
/// with parallel branching for creative exploration.
class DreamCycle {
  DreamCycle({
    required this.queries,
    required this.messageRepo,
    required this.agentLoop,
    required this.toolRegistry,
    required this.sendMessage,
    required this.botName,
    required this.buildSystemPrompt,
    this.lightRounds = defaultLightRounds,
    this.deepRounds = defaultDeepRounds,
    this.branchRounds = defaultBranchRounds,
    this.remRounds = defaultRemRounds,
  });

  final Queries queries;
  final MessageRepository messageRepo;
  final AgentLoop agentLoop;
  final ToolRegistry toolRegistry;
  final DreamSendMessageFn sendMessage;
  final String botName;

  /// Builds the system prompt for the dream's "waking up" summary message.
  final String Function(AgentInput input) buildSystemPrompt;

  /// Round budgets for each phase.
  final int lightRounds;
  final int deepRounds;
  final int branchRounds;
  final int remRounds;

  /// Whether a dream cycle is currently running. Prevents concurrent cycles.
  bool _running = false;

  /// Whether a dream cycle is currently in progress.
  bool get isRunning => _running;

  /// Triggers a dream cycle for [groupId] on [date].
  ///
  /// Returns `true` if the cycle was started, `false` if skipped (already
  /// running or already dreamed today).
  bool trigger({
    required String groupId,
    required String triggeredByUuid,
    required String date,
  }) {
    if (_running) {
      developer.log(
        'Dream cycle already running, skipping',
        name: 'DreamCycle',
      );
      return false;
    }

    final existing = queries.getDreamCycle(groupId, date);
    if (existing != null) {
      developer.log(
        'Already dreamed today for $groupId ($date)',
        name: 'DreamCycle',
      );
      return false;
    }

    _running = true;

    // Run asynchronously — never blocks the polling loop.
    _runDream(
      groupId: groupId,
      triggeredByUuid: triggeredByUuid,
      date: date,
    ).ignore();

    return true;
  }

  Future<void> _runDream({
    required String groupId,
    required String triggeredByUuid,
    required String date,
  }) async {
    final cycleId = queries.createDreamCycle(
      signalGroupId: groupId,
      date: date,
      triggeredByUuid: triggeredByUuid,
    );

    developer.log(
      'Dream cycle started for $groupId (id=$cycleId)',
      name: 'DreamCycle',
    );

    try {
      // Determine the "since" timestamp for chat history replay.
      final lastCycle = queries.getLastCompletedDreamCycle(groupId);
      final since = lastCycle?.startedAt ?? '1970-01-01T00:00:00';

      final chatHistory = messageRepo.getMessagesSince(
        chatId: groupId,
        since: since,
      );

      developer.log(
        'Replaying ${chatHistory.length} messages since $since',
        name: 'DreamCycle',
      );

      final identity = queries.getBotIdentity();
      final context = DreamContext(
        botName: botName,
        groupId: groupId,
        identity: identity,
      );

      final totalUsage = TokenUsage();
      var totalToolCalls = 0;
      var phasesCompleted = 0;
      var branchCount = 0;

      // ── Phase 1: Light Sleep (N1→N2) ──────────────────────────────────

      developer.log('Entering Light Sleep (N1→N2)', name: 'DreamCycle');

      final lightResult = await _runPhase(
        context: context,
        groupId: groupId,
        cycle: SleepCycle.light,
        chatHistory: chatHistory,
        previousSummaries: [],
        maxRounds: lightRounds,
      );

      totalUsage.inputTokens += lightResult.usage.inputTokens;
      totalUsage.outputTokens += lightResult.usage.outputTokens;
      totalToolCalls += lightResult.toolCallCount;
      phasesCompleted++;

      final lightSummary = stripDepthSignal(lightResult.text);

      developer.log(
        'Light Sleep done: ${lightResult.toolCallCount} tool calls, '
        '${lightResult.usage.totalTokens} tokens',
        name: 'DreamCycle',
      );

      // Check if there's anything worth going deeper for.
      final lightSignal = parseDepthSignal(
        lightResult.text,
        defaultSignal: DepthSignal.continue_,
      );

      String dreamReport;

      if (lightSignal == DepthSignal.wake) {
        developer.log(
          'Light Sleep signaled wake — skipping deeper phases',
          name: 'DreamCycle',
        );
        dreamReport = lightSummary;
      } else {
        // ── Phase 2: Deep Sleep (N2→N3) ─────────────────────────────────

        developer.log('Entering Deep Sleep (N2→N3)', name: 'DreamCycle');

        final deepResult = await _runPhase(
          context: context,
          groupId: groupId,
          cycle: SleepCycle.deep,
          chatHistory: chatHistory,
          previousSummaries: [lightSummary],
          maxRounds: deepRounds,
        );

        totalUsage.inputTokens += deepResult.usage.inputTokens;
        totalUsage.outputTokens += deepResult.usage.outputTokens;
        totalToolCalls += deepResult.toolCallCount;
        phasesCompleted++;

        final deepSummary = stripDepthSignal(deepResult.text);

        developer.log(
          'Deep Sleep done: ${deepResult.toolCallCount} tool calls, '
          '${deepResult.usage.totalTokens} tokens',
          name: 'DreamCycle',
        );

        // Parse sparks from Deep Sleep output.
        final sparks = parseSparks(deepResult.text);

        if (sparks.isEmpty) {
          developer.log(
            'No sparks found — skipping branching',
            name: 'DreamCycle',
          );
          dreamReport = deepSummary;
        } else {
          // ── Dream Branching (parallel N3 threads) ─────────────────────

          developer.log(
            'Branching into ${sparks.length} dream threads',
            name: 'DreamCycle',
          );
          branchCount = sparks.length;

          final branchFutures = <Future<AgentResult>>[];
          for (var i = 0; i < sparks.length; i++) {
            branchFutures.add(_runBranch(
              context: context,
              groupId: groupId,
              spark: sparks[i],
              branchNumber: i + 1,
              totalBranches: sparks.length,
              deepSummary: deepSummary,
            ));
          }

          final branchResults = await Future.wait(branchFutures);

          final branchReports = <String>[];
          for (final result in branchResults) {
            totalUsage.inputTokens += result.usage.inputTokens;
            totalUsage.outputTokens += result.usage.outputTokens;
            totalToolCalls += result.toolCallCount;
            branchReports.add(result.text);
          }

          developer.log(
            '${sparks.length} branches completed',
            name: 'DreamCycle',
          );

          // ── REM Convergence ─────────────────────────────────────────

          developer.log('Entering REM convergence', name: 'DreamCycle');

          final remResult = await _runConvergence(
            context: context,
            groupId: groupId,
            branchReports: branchReports,
            deepSummary: deepSummary,
          );

          totalUsage.inputTokens += remResult.usage.inputTokens;
          totalUsage.outputTokens += remResult.usage.outputTokens;
          totalToolCalls += remResult.toolCallCount;
          phasesCompleted++;

          dreamReport = remResult.text;

          developer.log(
            'REM convergence done: ${remResult.toolCallCount} tool calls, '
            '${remResult.usage.totalTokens} tokens',
            name: 'DreamCycle',
          );
        }
      }

      // Mark completed.
      queries.updateDreamCycle(
        cycleId,
        status: DreamCycleStatus.completed,
        completedAt: DateTime.now().toUtc().toIso8601String(),
      );

      developer.log(
        'Dream complete: $phasesCompleted phases, $branchCount branches, '
        '$totalToolCalls tool calls, ${totalUsage.totalTokens} tokens',
        name: 'DreamCycle',
      );

      // ── Waking message ──────────────────────────────────────────────

      if (dreamReport.isNotEmpty) {
        final stats = _formatDreamStats(
          phases: phasesCompleted,
          branches: branchCount,
          toolCalls: totalToolCalls,
          tokens: totalUsage.totalTokens,
        );

        final wakingInput = AgentInput(
          text: 'You just woke up from your dream cycle ($stats). '
              'Here is your dream report:\n\n$dreamReport\n\n'
              'Compose a brief, in-character "waking up" message for the '
              'group. Keep it to 2-4 sentences. Mention any interesting '
              'sparks or insights. Weave the dream stats naturally into '
              'the message — like stretching awake and recounting how '
              'deep you slept.',
          chatId: groupId,
          senderUuid: 'system',
          isAdmin: true,
          isSystemInitiated: true,
        );

        final wakingResult = await agentLoop.processMessageWithUsage(
          wakingInput,
          systemPrompt: buildSystemPrompt(wakingInput),
        );

        totalUsage.inputTokens += wakingResult.usage.inputTokens;
        totalUsage.outputTokens += wakingResult.usage.outputTokens;

        if (wakingResult.text.isNotEmpty) {
          await sendMessage(groupId, wakingResult.text);
        }
      }
    } on Exception catch (e) {
      developer.log(
        'Dream cycle failed for $groupId: $e',
        name: 'DreamCycle',
        level: 900,
      );
      queries.updateDreamCycle(
        cycleId,
        status: DreamCycleStatus.failed,
        completedAt: DateTime.now().toUtc().toIso8601String(),
        errorMessage: e.toString(),
      );
    } finally {
      _running = false;
    }
  }

  // -----------------------------------------------------------------------
  // Phase runners
  // -----------------------------------------------------------------------

  /// Runs a sequential sleep phase (Light or Deep).
  Future<AgentResult> _runPhase({
    required DreamContext context,
    required String groupId,
    required SleepCycle cycle,
    required List<PersistedMessage> chatHistory,
    required List<String> previousSummaries,
    required int maxRounds,
  }) {
    final prompt = buildDreamCyclePrompt(
      context: context,
      cycle: cycle,
      chatHistory: chatHistory,
      previousSummaries: previousSummaries,
    );

    final chatId = 'dream::$groupId::${cycle.number}';
    toolRegistry.setContext(ToolContext(
      senderUuid: 'system',
      isAdmin: true,
      chatId: chatId,
      isGroup: false,
    ));

    final input = AgentInput(
      text: 'Begin ${cycle.label}. '
          '${_phaseInstruction(cycle)}',
      chatId: chatId,
      senderUuid: 'system',
      isAdmin: true,
      isSystemInitiated: false,
    );

    return agentLoop.processMessageWithUsage(
      input,
      systemPrompt: prompt,
      maxToolRounds: maxRounds,
    );
  }

  /// Runs a single dream branch exploring one spark.
  Future<AgentResult> _runBranch({
    required DreamContext context,
    required String groupId,
    required String spark,
    required int branchNumber,
    required int totalBranches,
    required String deepSummary,
  }) {
    final prompt = buildDreamBranchPrompt(
      context: context,
      spark: spark,
      branchNumber: branchNumber,
      totalBranches: totalBranches,
      deepSummary: deepSummary,
    );

    final chatId = 'dream::$groupId::branch-$branchNumber';
    toolRegistry.setContext(ToolContext(
      senderUuid: 'system',
      isAdmin: true,
      chatId: chatId,
      isGroup: false,
    ));

    final input = AgentInput(
      text: 'You are dreaming about this spark: $spark\n\n'
          'Explore it fully. Follow where it leads.',
      chatId: chatId,
      senderUuid: 'system',
      isAdmin: true,
      isSystemInitiated: false,
    );

    return agentLoop.processMessageWithUsage(
      input,
      systemPrompt: prompt,
      maxToolRounds: branchRounds,
    );
  }

  /// Runs the REM convergence phase.
  Future<AgentResult> _runConvergence({
    required DreamContext context,
    required String groupId,
    required List<String> branchReports,
    required String deepSummary,
  }) {
    final prompt = buildDreamConvergencePrompt(
      context: context,
      branchReports: branchReports,
      deepSummary: deepSummary,
    );

    final chatId = 'dream::$groupId::rem';
    toolRegistry.setContext(ToolContext(
      senderUuid: 'system',
      isAdmin: true,
      chatId: chatId,
      isGroup: false,
    ));

    final input = AgentInput(
      text: 'Your dream threads are converging. Read all branch reports '
          'and synthesize your dream report.',
      chatId: chatId,
      senderUuid: 'system',
      isAdmin: true,
      isSystemInitiated: false,
    );

    return agentLoop.processMessageWithUsage(
      input,
      systemPrompt: prompt,
      maxToolRounds: remRounds,
    );
  }

  String _phaseInstruction(SleepCycle cycle) => switch (cycle) {
        SleepCycle.light =>
          'Review the chat history. Identify and file decisions, '
              'action items, and interesting themes.',
        SleepCycle.deep =>
          'Go deeper. Search existing Outline docs and Kan cards for '
              'connections. Surface sparks for branching.',
      };

  static String _formatDreamStats({
    required int phases,
    required int branches,
    required int toolCalls,
    required int tokens,
  }) {
    final parts = <String>[
      '$phases sleep phases',
      if (branches > 0) '$branches dream branches',
      '$toolCalls tool calls',
      '${_formatTokenCount(tokens)} tokens',
    ];
    return parts.join(', ');
  }

  static String _formatTokenCount(int tokens) {
    if (tokens < 1000) return tokens.toString();
    final s = tokens.toString();
    final result = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) result.write(',');
      result.write(s[i]);
    }
    return result.toString();
  }
}

/// Regex for detecting goodnight messages.
///
/// Matches: goodnight, good night, g'night, gnight, nighty night,
/// sleep well, sweet dreams (case-insensitive, word boundaries).
final goodnightPattern = RegExp(
  r"\b(?:good\s*night|g'?night|nighty\s*night|sleep\s+well|sweet\s+dreams)\b",
  caseSensitive: false,
);

/// Returns `true` if [text] contains a goodnight message.
bool isGoodnightMessage(String text) => goodnightPattern.hasMatch(text);
