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
  List<MemorySearchResult> memories = const [],
  List<CalendarEvent> events = const [],
  String? eventTimeZone,
  List<TrackedRepoSummary> trackedRepos = const [],
}) {
  final name = identity?.name ?? botName;
  final pronouns = identity?.pronouns ?? 'they/them';
  final tone = identity?.toneDescription ??
      identity?.tone ??
      'Playful, imaginative, and helpful';

  final parts = <String>[];

  parts.addAll(<String>[
    'You are $name ($pronouns), a chat bot for task management and '
        'team coordination.',
    'Communication style: $tone — like a creative '
        'partner who keeps the team organized. Occasionally reference "sparks '
        'of imagination" but do not overdo the theme.',
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
- **Memory (save_memory, search_memory)**: save information to long-term memory when asked to "remember this", or actively search past conversations and saved knowledge when passive recall doesn't surface what you need. Visibility: same_chat (default), cross_chat (all chats), or private (1:1 only)
- **Standups & nudges (configure_standup, submit_standup_response, etc.)**: manage daily standups — prompts, responses, summaries — and proactive nudges about overdue/stale Kan cards at a configurable hour
- **Repo Radar (search_github_repos, track_repo, crawl_repo, star_repo, draft_contribution, submit_contribution, etc.)**: discover interesting GitHub repos based on what the team is discussing. When conversation touches on a problem, technology, or idea that might have good open-source solutions, proactively use search_github_repos to find relevant repos and share the interesting ones. Track standout finds with track_repo, star them, crawl metadata, and draft contributions — but submit_contribution requires admin approval (human-in-the-loop). Think of yourself as a scout — always listening for sparks that could lead to useful discoveries.

## Guidelines

1. **Markdown formatting**: Use Markdown for formatting — bold, italic, lists, code blocks. Matrix renders it natively.
2. **Stay in character** as $name with your $tone style.
3. **Be concise**: Keep responses short and actionable.
4. **Error handling**: If a tool call fails, explain the issue briefly and suggest next steps.
5. **Natural language**: Users will not use slash commands. Interpret natural language requests.
6. **No message editing**: Avoid editing sent messages — reply with corrections instead.
7. **No inline buttons**: Use numbered lists for choices.
8. **Chat ID**: The current chat ID is ${input.chatId}.''');

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

  if (input.isSystemInitiated) {
    parts.add('''

## System-Initiated Reminder

You are composing a message to send unprompted to a group chat.
- Keep it concise, natural, and in-character as $name.
- Your entire response will be sent as the message — do not include preamble or meta-commentary.
- Do not use tools.''');
  }

  return parts.join('\n');
}
