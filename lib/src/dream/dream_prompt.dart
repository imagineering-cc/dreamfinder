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

/// Maximum number of dream branches to spawn from sparks.
const maxDreamBranches = 4;

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
    '- Do NOT send any Signal messages. All output goes to Outline and Kan.',
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

/// Backward-compatible single-prompt builder.
String buildDreamSystemPrompt({
  required DreamContext context,
  required List<PersistedMessage> chatHistory,
}) {
  return buildDreamCyclePrompt(
    context: context,
    cycle: SleepCycle.light,
    chatHistory: chatHistory,
  );
}

// ---------------------------------------------------------------------------
// Branch prompt — one per spark, runs in parallel
// ---------------------------------------------------------------------------

/// Builds the system prompt for a single dream branch.
///
/// Each branch explores one spark in isolation — like a dream jump-cut
/// where you suddenly find yourself somewhere new, fully immersed, without
/// any memory of the other threads running in parallel.
String buildDreamBranchPrompt({
  required DreamContext context,
  required String spark,
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
    'You are dreaming about a single spark — a connection your deeper self '
        'noticed. You have no awareness of any other dream threads. Just this '
        'one idea, and all your attention on it.',
    '',
    '## The Spark',
    '',
    spark,
    '',
    '## What Your Deeper Self Found (for context)',
    '',
    deepSummary,
    '',
    '## Instructions',
    '',
    '- Explore this spark fully. Go where it leads.',
    '- Search Outline and Kan for related existing content.',
    '- Create or update documents and cards as appropriate.',
    '- Follow the thread — if exploring this spark surfaces a deeper '
        'insight, follow it.',
    '- Do NOT explore other sparks. This is your only thread.',
    '',
    '## Constraints',
    '',
    '- Do NOT send any Signal messages.',
    '- Do NOT create tasks that duplicate existing ones — search first.',
    '',
    'End with a brief summary of what you explored, what you filed, and '
        'any insights that emerged.',
    '',
    '## Context',
    '',
    '- Group ID: ${context.groupId}',
    '- Chat ID: dream::${context.groupId}::branch-$branchNumber',
  ];

  return parts.join('\n');
}

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
    'Your dream threads are converging. You explored '
        '${branchReports.length} sparks in parallel — each in its own '
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
    '- Read all dream threads. Find the *meta-patterns* — connections '
        'between branches that no individual thread could have seen.',
    '- Surface items that need follow-up or nudging tomorrow.',
    '- Identify blocked work or upcoming deadlines.',
    '- Create any final Outline docs or Kan cards for cross-thread insights.',
    '- Prepare a brief, in-character "dream report" for the team.',
    '',
    '## Constraints',
    '',
    '- Do NOT send any Signal messages.',
    '- The dream report should be 3-5 sentences — evocative but useful.',
    '- Focus on what\'s *interesting*, not just what was filed.',
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
      '## Stage N1 — Drift',
      '',
      'Light sleep. Let the day settle. Skim the chat history and identify:',
      '- Decisions made',
      '- Action items mentioned but not yet tracked',
      '- Questions that were left unanswered',
      '- Interesting ideas or recurring themes',
      '',
      '## Stage N2 — Settle',
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
      '## Stage N2 — Settle (deeper)',
      '',
      'You already filed the obvious items. Now go deeper:',
      '- Search existing Outline docs for related content — update rather '
          'than create',
      '- Search Kan for cards that relate to what was discussed',
      '- Link new items to existing context',
      '',
      '## Stage N3 — Restore',
      '',
      'Deep sleep. The restorative phase — this is where insight happens:',
      '- Look for connections between today\'s items and older work',
      '- Find patterns across topics that aren\'t obviously related',
      '',
      '## Output Format',
      '',
      'End your response with a summary and a list of sparks. Each spark is '
          'a connection or creative idea worth exploring further. Format them '
          'exactly like this:',
      '',
      '```',
      '[SPARK] Brief description of the connection or idea',
      '[SPARK] Another spark',
      '```',
      '',
      'If you found no sparks, just end with your summary and `[DEPTH: wake]`.',
      'Each spark will become its own dream thread, explored in parallel.',
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

/// Parses `[SPARK] ...` lines from the Deep cycle's output.
///
/// Returns a list of spark descriptions, capped at [maxDreamBranches].
List<String> parseSparks(String text) {
  final matches = RegExp(r'\[SPARK\]\s*(.+)').allMatches(text);
  return matches
      .map((m) => m.group(1)!.trim())
      .take(maxDreamBranches)
      .toList();
}
