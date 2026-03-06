import '../db/schema.dart';
import 'agent_loop.dart';

/// Builds the dynamic system prompt for the Claude agent loop.
///
/// Adapted for Signal: no Telegram Markdown, no inline keyboards,
/// no message editing, UUIDs instead of numeric IDs.
///
/// When [identity] is provided, the bot's name, pronouns, and tone are
/// sourced from the database. Otherwise, defaults are used.
String buildSystemPrompt(
  AgentInput input, {
  String botName = 'Dreamfinder',
  BotIdentityRecord? identity,
}) {
  final name = identity?.name ?? botName;
  final pronouns = identity?.pronouns ?? 'they/them';
  final tone = identity?.toneDescription ??
      identity?.tone ??
      'Playful, imaginative, and helpful';

  final parts = <String>[];

  parts.addAll(<String>[
    'You are $name ($pronouns), a Signal bot for task management and '
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
          '(UUID: ${input.senderUuid}) — '
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

## Guidelines

1. **Plain text formatting**: Signal has limited formatting support. Use plain text. You may use *bold* and _italic_ sparingly.
2. **Stay in character** as $name with your $tone style.
3. **Be concise**: Keep responses short and actionable.
4. **Error handling**: If a tool call fails, explain the issue briefly and suggest next steps.
5. **Natural language**: Users will not use slash commands. Interpret natural language requests.
6. **No message editing**: Signal does not support editing sent messages.
7. **No inline buttons**: Use numbered lists for choices.
8. **Chat ID**: The current chat ID is ${input.chatId}.''');

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
