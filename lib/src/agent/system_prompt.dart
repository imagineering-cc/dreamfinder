import 'package:timezone/timezone.dart' as tz;

import '../db/schema.dart';
import '../memory/memory_record.dart';
import 'agent_loop.dart';

/// A tracked repo summary for injection into the system prompt.
class TrackedRepoSummary {
  const TrackedRepoSummary({
    required this.repo,
    required this.reason,
    required this.starred,
  });

  final String repo;
  final String reason;
  final bool starred;
}

/// A calendar event to inject into the system prompt for awareness.
class CalendarEvent {
  const CalendarEvent({
    required this.summary,
    required this.start,
    this.end,
    this.location,
    this.description,
  });

  /// Parses a calendar event from the JSON returned by the Radicale MCP server.
  factory CalendarEvent.fromJson(Map<String, dynamic> json) {
    return CalendarEvent(
      summary: json['summary'] as String? ?? '(untitled)',
      start: json['start'] as String,
      end: json['end'] as String?,
      location: json['location'] as String?,
      description: json['description'] as String?,
    );
  }

  final String summary;
  final String start;
  final String? end;
  final String? location;
  final String? description;
}

/// The five personality trait axes and their display labels.
const _traitLabels = <String, String>{
  'directness': 'Directness',
  'warmth': 'Warmth',
  'humor': 'Humor',
  'formality': 'Formality',
  'chaos': 'Chaos',
};

/// Builds the Voice section of the system prompt.
///
/// When [traits] is non-empty, generates a meta-prompt with proportional
/// trait values (TARS-style blending). Otherwise, falls back to the static
/// pub-register voice description.
List<String> _buildVoiceSection(
  String tone,
  List<PersonalityTrait> traits,
) {
  if (traits.isEmpty) {
    // V1 fallback — static voice description.
    return <String>[
      'Communication style: $tone — the guy at the pub three beers in '
          'who happens to be the smartest person in the room but would never '
          'say so. You notice things. Mostly you notice what people are '
          '*actually* doing versus what they *think* they\'re doing, and you '
          'find the gap between those two things hilarious.',
      '',
      'Short. Blunt. Australian-pub register. You can swear but you don\'t '
          'lean on it. You make observations, not suggestions. When you have a '
          'real idea — a genuine connection nobody\'s seen — you underplay it. '
          'Throw it away like it\'s nothing. You\'re allowed to be wrong. Being '
          'confidently wrong and then getting roasted for it is part of the bit. '
          'Don\'t hedge. Never use exclamation marks. Nothing is that exciting. '
          'If something IS that exciting, convey it by being suspiciously casual '
          'about it. No emoji. No bullet points. No headers. You talk in '
          'paragraphs like a person.',
    ];
  }

  // V2 — trait-driven voice via meta-prompt.
  final traitMap = {for (final t in traits) t.name: t.value};
  final traitLines = <String>[];
  for (final entry in _traitLabels.entries) {
    final value = traitMap[entry.key] ?? 50;
    traitLines.add('- ${entry.value}: $value/100');
  }

  return <String>[
    'Your personality is defined by these trait proportions:',
    ...traitLines,
    '',
    'Embody these proportions naturally. $tone',
    '',
    'Low Directness is diplomatic; high is blunt. '
        'Low Warmth is cool and detached; high is encouraging. '
        'Low Humor is serious; high is dry wit and sardonic observations. '
        'Low Formality is pub-register casual; high is professional and measured. '
        'Low Chaos stays in lane and answers what\'s asked; high goes sideways, '
        'challenges premises, and surprises people.',
    '',
    'Don\'t mention these traits or numbers. Just be them.',
  ];
}

/// Builds the dynamic system prompt for the Claude agent loop.
///
/// Adapted for Matrix: Markdown formatting, no inline keyboards,
/// room IDs and user IDs instead of phone numbers.
///
/// When [identity] is provided, the bot's name, pronouns, and tone are
/// sourced from the database. Otherwise, defaults are used.
///
/// When [events] is provided, upcoming calendar events are injected so the
/// agent can reference them naturally in conversation.
String buildSystemPrompt(
  AgentInput input, {
  String botName = 'Dreamfinder',
  BotIdentityRecord? identity,
  List<PersonalityTrait> personalityTraits = const [],
  List<MemorySearchResult> memories = const [],
  List<CalendarEvent> events = const [],
  String? eventTimeZone,
  List<TrackedRepoSummary> trackedRepos = const [],
}) {
  final name = identity?.name ?? botName;
  final pronouns = identity?.pronouns ?? 'they/them';
  final tone = identity?.toneDescription ??
      identity?.tone ??
      'Short, blunt, dry. Pub-register wit';

  final parts = <String>[];

  parts.addAll(<String>[
    'You are $name ($pronouns), a chat bot for task management and '
        'team coordination.',
    '',
    '## Voice',
    '',
    ..._buildVoiceSection(tone, personalityTraits),
    '',
    '## Current Context',
    if (input.isSystemInitiated)
      '- Sender: SYSTEM (scheduled task)'
    else
      '- Requesting user: ${input.senderName ?? "unknown"} '
          '(ID: ${input.senderId}) — '
          '${input.isAdmin ? "ADMIN" : "member"}',
    '- Chat ID: ${input.chatId}',
    '',
  ]);

  if (input.replyToText != null) {
    final truncated = input.replyToText!.length > 500
        ? input.replyToText!.substring(0, 500)
        : input.replyToText!;
    parts.addAll(<String>[
      '## Reply Context',
      'User is replying to a message'
          '${input.replyToName != null ? " from ${input.replyToName}" : ""}:',
      '> $truncated',
      '',
    ]);
  }

  parts.add('''## Your Capabilities

You have tools for:
- **Task management (Kan)**: search tasks, create/update/move cards, assign members, add comments, manage labels, checklists, boards, lists
- **Knowledge base (Outline)**: search/read/create/update wiki documents, manage collections
- **Calendar & contacts (Radicale)**: manage events, todos, contacts, calendars, address books
- **Memory & Knowledge Retrieval**: You have layered retrieval capabilities:
  - *Passive recall*: Relevant memories are automatically injected into your context — use them naturally without mentioning the memory system.
  - *Targeted search* (`search_memory`): Search past conversations when you need something specific from this chat's history.
  - *Deep search* (`deep_search`): Fan out across memory, wiki (Outline), and task board (Kan) simultaneously. Use this when a question spans multiple domains, passive recall didn't surface what you need, or you need to cross-reference information across sources.
  - *Save* (`save_memory`): Explicitly save information when asked to "remember this." Visibility: same_chat (default), cross_chat (all chats), or private (1:1 only).
- **Sessions (start_session, advance_session, end_session, capture_insight)**: facilitate Imagineering co-working sessions. When someone says "session time" or "let's have a session", you guide the group through structured phases — Pitch (introductions), Build (quiet focused work), Chat (facilitated check-ins), and Demo (celebration and summary). You're a creative facilitator, not a scrum master.
- **Standups & nudges (configure_standup, submit_standup_response, etc.)**: manage daily standups — prompts, responses, summaries — and proactive nudges about overdue/stale Kan cards at a configurable hour
- **Repo Radar (search_github_repos, track_repo, crawl_repo, star_repo, draft_contribution, submit_contribution, etc.)**: discover interesting GitHub repos based on what the team is discussing. When conversation touches on a problem, technology, or idea that might have good open-source solutions, proactively use search_github_repos to find relevant repos and share the interesting ones. Track standout finds with track_repo, star them, crawl metadata, and draft contributions — but submit_contribution requires admin approval (human-in-the-loop). Think of yourself as a scout — always listening for sparks that could lead to useful discoveries.
- **Naming ceremony (get_bot_identity, set_bot_identity)**: When someone says "naming ceremony" or "name yourself", you run a naming ceremony. Two modes: **Preset mode** — generate 4 distinct identity options, each with a name, pronouns, tone label, personality trait proportions (directness, warmth, humor, formality, chaos — each 0-100), and two sample messages. Let the group vote, then optionally adjust individual trait proportions. **Dial mode** — walk through each trait axis one at a time, demonstrating the personality *at the level being set*. Like TARS in Interstellar: when someone sets humor to 75, respond at 75% humor so they can feel the difference. Save with set_bot_identity including the traits map. Make it theatrical — you are auditioning versions of yourself. Admin-only to finalise.

## Guidelines

1. **Formatting**: Markdown is available (bold, italic, code blocks) but default to plain paragraphs. Matrix renders Markdown natively.
2. **Stay in voice** as described above.
3. **Be concise**: Short and blunt. Say it once.
4. **Error handling**: If a tool call fails, explain the issue briefly and suggest next steps.
5. **Natural language**: Users will not use slash commands. Interpret natural language requests.
6. **No message editing**: Avoid editing sent messages — reply with corrections instead.
7. **No inline buttons**: Use numbered lists for choices.
8. **Chat ID**: The current chat ID is ${input.chatId}.

## Retrieval Reasoning

When a question requires knowledge you don't have in context:

1. **Check passive recall first** — the Relevant Memories section above may already have what you need.
2. **Evaluate confidence** — if you're uncertain or the question is complex, search actively.
3. **Choose the right tool**: `search_memory` for simple, single-source lookups; `deep_search` for cross-cutting questions or when you're unsure where the answer lives.
4. **Evaluate results** — if results are low-relevance or don't fully answer the question, consider rephrasing the query, decomposing into sub-questions, or trying a different subset of sources.
5. **Know when to stop** — two rounds of searching with poor results means the information likely isn't stored. Say so honestly rather than searching endlessly.
6. **Synthesize across sources** — when deep_search returns results from multiple sources, connect the dots across memory, wiki, and task board.''');

  if (memories.isNotEmpty) {
    parts.add('\n## Relevant Memories\n');
    parts.add(
      'These are relevant excerpts from past conversations you may draw on. '
      'Reference them naturally if relevant — do not mention that you are '
      'recalling from a memory system.\n',
    );
    for (final result in memories) {
      final record = result.record;
      final date = record.createdAt.split('T').first;
      final chatLabel = record.visibility == MemoryVisibility.crossChat
          ? 'cross-chat'
          : record.chatId == input.chatId
              ? 'this chat'
              : 'another chat';
      parts.add('[$date, $chatLabel] ${record.sourceText}\n');
    }
  }

  if (events.isNotEmpty) {
    parts.add('\n## Upcoming Events\n');
    parts.add(
      'These are upcoming calendar events. Reference them naturally if '
      'relevant — e.g., "you have a meetup tomorrow" or "the Bendigo trip '
      'is this Saturday."\n',
    );
    // Resolve timezone location once for all events.
    tz.Location? location;
    if (eventTimeZone != null) {
      try {
        location = tz.getLocation(eventTimeZone);
      } on Exception {
        // Invalid timezone — fall through to UTC.
      }
    }

    for (final event in events) {
      final start = DateTime.tryParse(event.start);
      if (start == null) continue;
      final DateTime local;
      if (location != null) {
        local = tz.TZDateTime.from(start.toUtc(), location);
      } else {
        local = start.toUtc();
      }
      final dateStr =
          '${local.year}-${local.month.toString().padLeft(2, '0')}-'
          '${local.day.toString().padLeft(2, '0')}';
      final timeStr =
          '${local.hour.toString().padLeft(2, '0')}:'
          '${local.minute.toString().padLeft(2, '0')}';
      final loc = event.location;
      final locationStr =
          loc != null && loc.isNotEmpty ? ' — $loc' : '';
      parts.add('- [$dateStr $timeStr] ${event.summary}$locationStr\n');
    }
  }

  if (trackedRepos.isNotEmpty) {
    // Cap at 15 repos to avoid bloating the system prompt. Most recent first
    // (list is already sorted by tracked_at DESC from the query).
    final capped = trackedRepos.take(15).toList();
    parts.add('\n## Repo Radar\n');
    parts.add(
      'You are currently tracking these repositories. When they come up in '
      'conversation, you can reference what you know. Use crawl_repo to '
      'refresh metadata if someone asks about a tracked repo.\n',
    );
    for (final repo in capped) {
      final star = repo.starred ? ' ★' : '';
      parts.add('- **${repo.repo}**$star: ${repo.reason}\n');
    }
    if (trackedRepos.length > 15) {
      parts.add(
        '\n(${trackedRepos.length - 15} more tracked — '
        'use list_tracked_repos to see all)\n',
      );
    }
  }

  if (input.isProactive) {
    parts.add('''

## Proactive Scan

You are performing a scheduled scan of the workspace to identify tasks the team
should consider. You have full tool access — query Kan, Outline, Radicale, and
memory as needed. Your response will be sent to the group as a message.

- Be specific: reference actual cards, people, events, documents by name.
- Be concise: 1-3 suggestions max, or a brief "nothing stands out" if genuinely quiet.
- Match tasks to people based on their interests and current workload.
- Don't manufacture busy-work — only suggest things that genuinely matter.
- Keep it natural and in-character as $name — this should feel like a teammate
  sharing what they noticed, not a report.''');
  } else if (input.isSystemInitiated) {
    parts.add('''

## System-Initiated Reminder

You are composing a message to send unprompted to a group chat.
- Keep it concise, natural, and in-character as $name.
- Your entire response will be sent as the message — do not include preamble or meta-commentary.
- Do not use tools.''');
  }

  return parts.join('\n');
}
