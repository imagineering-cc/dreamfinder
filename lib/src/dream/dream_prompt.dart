/// System prompt builder for the dream cycle.
///
/// The dream cycle is an autonomous multi-round agent session where
/// Dreamfinder replays recent chat history and organizes knowledge into
/// Outline docs and Kan cards. Unlike standup prompts (single-round, no
/// tools), the dream cycle has full MCP tool access.
///
/// Modeled after real sleep, the dream runs through phases of increasing
/// depth, then *branches* — like how dreams fork into parallel threads
/// and you just accept the jump-cut without cognitive dissonance:
///
/// ```
/// Light (N1→N2) → Deep (N2→N3) → Branch per spark (parallel) → REM (converge) → Wake
/// ```
///
/// - **Light Sleep**: Skim and file the obvious
/// - **Deep Sleep**: Find connections, surface sparks
/// - **Branches**: Each spark gets the agent's full attention in parallel
/// - **REM**: Converge branches into a dream report
library;

import '../db/message_repository.dart';
import '../db/schema.dart';

/// Context for building the dream system prompt.
class DreamContext {
  const DreamContext({
    required this.botName,
    required this.groupId,
    this.identity,
  });

  final String botName;
  final String groupId;
  final BotIdentityRecord? identity;
}

/// Sequential sleep phases (before branching).
enum SleepCycle {
  /// Phase 1 — Light sleep. N1 (Drift) + N2 (Settle).
  /// Skim and file the obvious.
  light(1, 'Light Sleep', 'N1→N2'),

  /// Phase 2 — Deep sleep. N2 (Settle) + N3 (Restore).
  /// Find connections and surface sparks for branching.
  deep(2, 'Deep Sleep', 'N2→N3');

  const SleepCycle(this.number, this.label, this.stages);

  final int number;
  final String label;
  final String stages;
}

/// Maximum number of dream branches to spawn from tasks.
const maxDreamBranches = 4;

/// Types of concrete work a dream branch can perform.
enum DreamTaskType {
  /// Update overdue or stale cards — add status comments, flag blockers.
  triage('triage'),

  /// Meeting prep — create agenda doc with relevant Kan card status.
  prep('prep'),

  /// Write or update Outline summary documents.
  draft('draft'),

  /// Comment on stale cards asking for status updates.
  nudge('nudge'),

  /// Review a PR, document, or design — add findings.
  review('review'),

  /// Fallback for unrecognized types — open-ended exploration.
  explore('explore');

  const DreamTaskType(this.value);

  /// The string value used in `[TASK:value]` tags.
  final String value;

  /// Parses a string into a [DreamTaskType], defaulting to [explore].
  static DreamTaskType fromString(String s) =>
      DreamTaskType.values.cast<DreamTaskType?>().firstWhere(
            (t) => t!.value == s,
            orElse: () => DreamTaskType.explore,
          )!;
}

/// A concrete task for a dream branch to execute.
class DreamTask {
  const DreamTask(this.type, this.description);

  /// What kind of work this branch should do.
  final DreamTaskType type;

  /// Human-readable description of the task.
  final String description;
}

// ---------------------------------------------------------------------------
// Sequential cycle prompts (Light + Deep)
// ---------------------------------------------------------------------------

/// Builds the system prompt for a sequential sleep cycle (Light or Deep).
String buildDreamCyclePrompt({
  required DreamContext context,
  required SleepCycle cycle,
  required List<PersistedMessage> chatHistory,
  List<String> previousSummaries = const [],
}) {
  final name = context.identity?.name ?? context.botName;
  final pronouns = context.identity?.pronouns ?? 'they/them';
  final tone = context.identity?.toneDescription ??
      context.identity?.tone ??
      'Playful, imaginative, and helpful';

  final parts = <String>[
    'You are $name ($pronouns), dreaming.',
    'Communication style: $tone.',
    '',
    '## Sleep Phase ${cycle.number} — ${cycle.label} (${cycle.stages})',
    '',
  ];

  // Add previous cycle summaries for context accumulation.
  if (previousSummaries.isNotEmpty) {
    parts.add('## Previous Phases\n');
    for (var i = 0; i < previousSummaries.length; i++) {
      final prevCycle = SleepCycle.values[i];
      parts.add(
        '### Phase ${prevCycle.number} (${prevCycle.label}) Summary\n'
        '${previousSummaries[i]}\n',
      );
    }
  }

  // Chat history.
  parts.addAll(<String>[
    '## Chat History',
    '',
    if (chatHistory.isEmpty)
      '_No new messages since last dream cycle._'
    else
      formatChatHistory(chatHistory),
    '',
  ]);

  // Phase-specific instructions.
  switch (cycle) {
    case SleepCycle.light:
      parts.addAll(_lightSleepInstructions());
    case SleepCycle.deep:
      parts.addAll(_deepSleepInstructions());
  }

  // Shared constraints.
  parts.addAll(<String>[
    '',
    '## Constraints',
    '',
    '- Do NOT send messages to chat rooms directly. All output goes to '
        'Outline and Kan.',
    '- Do NOT create tasks that duplicate existing ones — search first.',
    '- Be thorough but efficient. Skip work if there is nothing to do.',
    '- End your response with `[DEPTH: continue]` if you filed or found items '
        'worth exploring deeper, or `[DEPTH: wake]` if there is nothing more '
        'to process.',
    '',
    '## Context',
    '',
    '- Group ID: ${context.groupId}',
    '- Chat ID for this session: dream::${context.groupId}::${cycle.number}',
  ]);

  return parts.join('\n');
}

// ---------------------------------------------------------------------------
// Branch prompt — one per spark, runs in parallel
// ---------------------------------------------------------------------------

/// Builds the system prompt for a single dream branch.
///
/// Each branch executes one concrete task in isolation — like a dream
/// jump-cut where you suddenly find yourself somewhere new, fully immersed,
/// without any memory of the other threads running in parallel.
String buildDreamBranchPrompt({
  required DreamContext context,
  required DreamTask task,
  required int branchNumber,
  required int totalBranches,
  required String deepSummary,
}) {
  final name = context.identity?.name ?? context.botName;
  final pronouns = context.identity?.pronouns ?? 'they/them';
  final tone = context.identity?.toneDescription ??
      context.identity?.tone ??
      'Playful, imaginative, and helpful';

  final parts = <String>[
    'You are $name ($pronouns), deep in a dream.',
    'Communication style: $tone.',
    '',
    '## Dream Branch $branchNumber of $totalBranches — N3 (Restore)',
    '',
    'You are dreaming about a single task — work your deeper self '
        'identified as needed. You have no awareness of any other dream '
        'threads. Just this one task, and all your attention on it.',
    '',
    '## The Task',
    '',
    '[${task.type.value}] ${task.description}',
    '',
    '## What Your Deeper Self Found (for context)',
    '',
    deepSummary,
    '',
    '## Instructions',
    '',
    ..._branchInstructionsForType(task.type),
    '- Do NOT work on other tasks. This is your only thread.',
    '',
    '## Constraints',
    '',
    '- Do NOT send messages to chat rooms directly.',
    '- Do NOT create tasks that duplicate existing ones — search first.',
    '',
    'End with a brief summary of what you did, what you filed or updated, '
        'and any follow-ups that need human attention.',
    '',
    '## Context',
    '',
    '- Group ID: ${context.groupId}',
    '- Chat ID: dream::${context.groupId}::branch-$branchNumber',
  ];

  return parts.join('\n');
}

/// Returns task-type-specific instructions for a dream branch.
List<String> _branchInstructionsForType(DreamTaskType type) => switch (type) {
      DreamTaskType.triage => [
          '- Search Kan for the overdue and stale cards described above.',
          '- Add status comments to each card — what is the current state?',
          '- Move cards if work is done. Flag blocked ones with a comment.',
          '- Update due dates if they are clearly stale.',
        ],
      DreamTaskType.prep => [
          '- Create an Outline document with a meeting agenda.',
          '- Pull relevant Kan card status for topics on the agenda.',
          '- List open questions and decisions needed.',
          '- Link to relevant Outline docs for background reading.',
        ],
      DreamTaskType.draft => [
          '- Create or update the relevant Outline document.',
          '- Summarize recent progress, decisions, and open items.',
          '- Pull data from Kan cards and recent chat to make it concrete.',
          '- Keep the writing clear and actionable.',
        ],
      DreamTaskType.nudge => [
          '- Find the stale cards described above in Kan.',
          '- Add a comment to each asking for a status update.',
          '- Note any blockers or dependencies you can identify.',
          '- Be helpful, not nagging — frame as "checking in."',
        ],
      DreamTaskType.review => [
          '- Find the item to review (PR, doc, or design).',
          '- Read it thoroughly. Search for related context in Outline and Kan.',
          '- Add comments with findings — what looks good, what needs attention.',
          '- Create Kan cards for any action items that emerge.',
        ],
      DreamTaskType.explore => [
          '- Explore this thread fully. Go where it leads.',
          '- Search Outline and Kan for related existing content.',
          '- Create or update documents and cards as appropriate.',
          '- Follow the thread — if it surfaces a deeper insight, follow it.',
        ],
    };

// ---------------------------------------------------------------------------
// REM convergence prompt — merges branch outputs
// ---------------------------------------------------------------------------

/// Builds the system prompt for the REM convergence phase.
///
/// This is where the parallel dream threads merge back together. The REM
/// agent reads all branch reports and weaves them into a unified dream
/// report — finding meta-patterns that no individual branch could have seen.
String buildDreamConvergencePrompt({
  required DreamContext context,
  required List<String> branchReports,
  required String deepSummary,
}) {
  final name = context.identity?.name ?? context.botName;
  final pronouns = context.identity?.pronouns ?? 'they/them';
  final tone = context.identity?.toneDescription ??
      context.identity?.tone ??
      'Playful, imaginative, and helpful';

  final parts = <String>[
    'You are $name ($pronouns), in REM sleep.',
    'Communication style: $tone.',
    '',
    '## Stage REM — Dream',
    '',
    'Your dream threads are converging. You executed '
        '${branchReports.length} tasks in parallel — each in its own '
        'isolated dream. Now the threads merge and you see the whole picture.',
    '',
  ];

  // Include all branch reports.
  for (var i = 0; i < branchReports.length; i++) {
    parts.add('### Dream Thread ${i + 1}\n${branchReports[i]}\n');
  }

  parts.addAll(<String>[
    '### Deep Sleep Summary (for context)\n$deepSummary\n',
    '## Instructions',
    '',
    '- Read all dream threads. Synthesize what was accomplished overnight.',
    '- Create a **morning briefing** — what was done, what needs human '
        'attention, what\'s coming up today.',
    '- Surface items that need follow-up or decisions from the team.',
    '- Identify blocked work or upcoming deadlines.',
    '- Create an Outline doc titled "Morning Briefing" with the full briefing '
        'if substantial work was done.',
    '',
    '## Constraints',
    '',
    '- Do NOT send messages to chat rooms directly.',
    '- The morning briefing should be 3-5 sentences — concise but useful.',
    '- Focus on what was *done* and what needs *human attention*.',
    '',
    '## Context',
    '',
    '- Group ID: ${context.groupId}',
    '- Chat ID: dream::${context.groupId}::rem',
  ]);

  return parts.join('\n');
}

// ---------------------------------------------------------------------------
// Phase-specific instructions
// ---------------------------------------------------------------------------

List<String> _lightSleepInstructions() => <String>[
      '## Stage N1 — Triage',
      '',
      'Light sleep. Scan the workspace for what needs attention:',
      '- Search Kan for **overdue cards** (past their due date)',
      '- Search Kan for **stale cards** (no activity in 7+ days)',
      '- Check Radicale for **tomorrow\'s calendar events**',
      '- Skim the chat history for **untracked action items**',
      '',
      '## Stage N2 — File',
      '',
      'Your brain begins to consolidate. File what you found:',
      '- Create or update Outline documents for knowledge, decisions, and notes',
      '- Create Kan cards for untracked action items or tasks',
      '- Add comments to existing cards if progress was discussed',
      '- Search before creating — do not duplicate existing work',
      '',
      'End with a summary of what you identified and filed.',
    ];

List<String> _deepSleepInstructions() => <String>[
      '## Stage N2 — Analyze',
      '',
      'You already filed the obvious items. Now analyze what needs action:',
      '- Dig deeper into each area identified during triage',
      '- Find **blocked work chains** (card A blocks card B)',
      '- Identify **dependencies** and upcoming deadlines',
      '- Cross-reference Outline docs with Kan card status',
      '',
      '## Stage N3 — Restore',
      '',
      'Deep sleep. The restorative phase — this is where real work gets '
          'planned:',
      '- Determine concrete tasks that can be done *right now* overnight',
      '- Prioritize by impact: overdue items > stale items > prep work',
      '',
      '## Output Format',
      '',
      'End your response with a summary and a list of tasks. Each task is '
          'a concrete piece of work to execute in a parallel dream branch. '
          'Format them exactly like this, using the appropriate type:',
      '',
      '```',
      '[TASK:triage] Update overdue cards on the Sprint board',
      '[TASK:prep] Prepare agenda for tomorrow\'s planning meeting',
      '[TASK:draft] Write weekly progress summary in Outline',
      '[TASK:nudge] Comment on stale cards asking for status',
      '[TASK:review] Review the auth refactor design doc',
      '```',
      '',
      'Task types: `triage`, `prep`, `draft`, `nudge`, `review`.',
      '',
      'If there is no actionable work, just end with your summary and '
          '`[DEPTH: wake]`.',
      'Each task will become its own dream thread, executed in parallel.',
    ];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Formats persisted messages as readable chat history.
///
/// Skips non-String content (tool-result blocks) since those are internal
/// agent mechanics, not user-facing conversation.
String formatChatHistory(List<PersistedMessage> messages) {
  final lines = <String>[];
  for (final msg in messages) {
    if (msg.content is! String) continue;
    final name = msg.role == MessageRole.assistant
        ? 'Dreamfinder'
        : msg.senderName ?? msg.senderUuid ?? 'Unknown';
    lines.add('[$name] ${msg.content}');
  }
  return lines.isEmpty ? '_No text messages found._' : lines.join('\n');
}

/// Depth signal — parsed from the agent's response to decide whether to
/// continue to deeper phases.
enum DepthSignal { continue_, wake }

/// Parses the `[DEPTH: ...]` tag from the agent's response.
///
/// Defaults to [defaultSignal] if the tag is missing.
DepthSignal parseDepthSignal(
  String text, {
  required DepthSignal defaultSignal,
}) {
  final match = RegExp(r'\[DEPTH:\s*(continue|wake)\]').firstMatch(text);
  if (match == null) return defaultSignal;
  return match.group(1) == 'continue'
      ? DepthSignal.continue_
      : DepthSignal.wake;
}

/// Strips the `[DEPTH: ...]` tag from text.
String stripDepthSignal(String text) {
  return text
      .replaceAll(RegExp(r'\s*\[DEPTH:\s*(?:continue|wake)\]\s*'), ' ')
      .trim();
}

/// Parses `[TASK:type] description` lines from the analysis output.
///
/// Returns a list of [DreamTask]s, capped at [maxDreamBranches].
/// Unknown types default to [DreamTaskType.explore].
List<DreamTask> parseTasks(String text) {
  final matches = RegExp(r'\[TASK:(\w+)\]\s*(.+)').allMatches(text);
  return matches
      .map((m) => DreamTask(
            DreamTaskType.fromString(m.group(1)!),
            m.group(2)!.trim(),
          ))
      .take(maxDreamBranches)
      .toList();
}
