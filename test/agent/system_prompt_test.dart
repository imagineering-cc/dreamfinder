import 'package:dreamfinder/src/agent/agent_loop.dart';
import 'package:dreamfinder/src/agent/system_prompt.dart';
import 'package:dreamfinder/src/db/schema.dart';
import 'package:dreamfinder/src/memory/memory_record.dart';
import 'package:test/test.dart';

void main() {
  group('buildSystemPrompt', () {
    test('includes System-Initiated Reminder section when flag is true', () {
      const input = AgentInput(
        text: 'Send standup prompt',
        chatId: 'group-1',
        senderId: 'system',
        isAdmin: true,
        isSystemInitiated: true,
      );
      final prompt = buildSystemPrompt(input);

      expect(prompt, contains('Sender: SYSTEM (scheduled task)'));
      expect(prompt, contains('## System-Initiated Reminder'));
      expect(prompt, contains('composing a message to send unprompted'));
      // Should NOT contain the normal user line.
      expect(prompt, isNot(contains('Requesting user:')));
    });

    test('uses normal context section when flag is false', () {
      const input = AgentInput(
        text: 'Hello',
        chatId: 'group-1',
        senderId: 'user-1',
        senderName: 'Alice',
        isAdmin: false,
      );
      final prompt = buildSystemPrompt(input);

      expect(prompt, contains('Requesting user: Alice'));
      expect(prompt, isNot(contains('System-Initiated Reminder')));
      expect(prompt, isNot(contains('SYSTEM (scheduled task)')));
    });

    test('includes Relevant Memories section when memories provided', () {
      const input = AgentInput(
        text: 'Tell me about the Dawn Gate',
        chatId: 'group-1',
        senderId: 'user-1',
        senderName: 'Nick',
        isAdmin: true,
      );
      final memories = [
        const MemorySearchResult(
          record: MemoryRecord(
            id: 1,
            chatId: 'group-1',
            sourceType: MemorySourceType.message,
            sourceText:
                'Nick: What is the Dawn Gate?\nDreamfinder: The Dawn Gate is '
                'an emoji gateway I spontaneously created...',
            visibility: MemoryVisibility.sameChat,
            createdAt: '2026-03-01T12:00:00',
          ),
          score: 0.95,
        ),
      ];

      final prompt = buildSystemPrompt(input, memories: memories);

      expect(prompt, contains('## Relevant Memories'));
      expect(prompt, contains('Dawn Gate'));
      expect(prompt, contains('[2026-03-01, this chat]'));
      expect(prompt, contains('do not mention that you are recalling'));
    });

    test('shows cross-chat label for cross_chat visibility', () {
      const input = AgentInput(
        text: 'Hello',
        chatId: 'group-1',
        senderId: 'user-1',
        isAdmin: false,
      );
      final memories = [
        const MemorySearchResult(
          record: MemoryRecord(
            id: 2,
            chatId: 'group-2',
            sourceType: MemorySourceType.message,
            sourceText: 'Shared knowledge across chats.',
            visibility: MemoryVisibility.crossChat,
            createdAt: '2026-03-05T10:00:00',
          ),
          score: 0.8,
        ),
      ];

      final prompt = buildSystemPrompt(input, memories: memories);
      expect(prompt, contains('[2026-03-05, cross-chat]'));
    });

    test('omits Relevant Memories section when no memories', () {
      const input = AgentInput(
        text: 'Hello',
        chatId: 'group-1',
        senderId: 'user-1',
        isAdmin: false,
      );
      final prompt = buildSystemPrompt(input);
      // The capabilities mention "Relevant Memories" in guidance text, but the
      // actual injected section header should not appear without memories.
      expect(prompt, isNot(contains('## Relevant Memories')));
    });

    test('mentions save_memory in capabilities', () {
      const input = AgentInput(
        text: 'Hello',
        chatId: 'group-1',
        senderId: 'user-1',
        isAdmin: false,
      );
      final prompt = buildSystemPrompt(input);
      expect(prompt, contains('save_memory'));
      expect(prompt, contains('remember this'));
    });

    test('defaults isSystemInitiated to false', () {
      const input = AgentInput(
        text: 'Hello',
        chatId: 'group-1',
        senderId: 'user-1',
        isAdmin: false,
      );
      final prompt = buildSystemPrompt(input);

      expect(prompt, contains('Requesting user:'));
      expect(prompt, isNot(contains('System-Initiated Reminder')));
    });

    test('includes Repo Radar section when tracked repos provided', () {
      const input = AgentInput(
        text: 'Hello',
        chatId: 'group-1',
        senderId: 'user-1',
        isAdmin: false,
      );
      final prompt = buildSystemPrompt(
        input,
        trackedRepos: const [
          TrackedRepoSummary(
            repo: 'dart-lang/sdk',
            reason: 'Core Dart SDK',
            starred: true,
          ),
          TrackedRepoSummary(
            repo: 'flutter/flutter',
            reason: 'Mobile framework',
            starred: false,
          ),
        ],
      );

      expect(prompt, contains('## Repo Radar'));
      expect(prompt, contains('**dart-lang/sdk** ★'));
      expect(prompt, contains('Core Dart SDK'));
      expect(prompt, contains('**flutter/flutter**:'));
      expect(prompt, isNot(contains('flutter/flutter** ★')));
    });

    test('omits Repo Radar context section when no tracked repos', () {
      const input = AgentInput(
        text: 'Hello',
        chatId: 'group-1',
        senderId: 'user-1',
        isAdmin: false,
      );
      final prompt = buildSystemPrompt(input);
      // Capabilities mention Repo Radar, but the context section should not
      // appear when there are no tracked repos.
      expect(prompt, isNot(contains('## Repo Radar')));
    });

    test('mentions Repo Radar in capabilities', () {
      const input = AgentInput(
        text: 'Hello',
        chatId: 'group-1',
        senderId: 'user-1',
        isAdmin: false,
      );
      final prompt = buildSystemPrompt(input);
      expect(prompt, contains('track_repo'));
      expect(prompt, contains('draft_contribution'));
      expect(prompt, contains('human-in-the-loop'));
    });

    test('identifies as chat bot, not Signal bot', () {
      const input = AgentInput(
        text: 'Hello',
        chatId: 'group-1',
        senderId: 'user-1',
        isAdmin: false,
      );
      final prompt = buildSystemPrompt(input);

      expect(prompt, contains('chat bot'));
      expect(prompt, isNot(contains('Signal bot')));
    });

    test('recommends Markdown formatting', () {
      const input = AgentInput(
        text: 'Hello',
        chatId: 'group-1',
        senderId: 'user-1',
        isAdmin: false,
      );
      final prompt = buildSystemPrompt(input);

      expect(prompt, contains('Markdown'));
      expect(prompt, isNot(contains('Signal has limited')));
    });

    test('mentions standup and nudge capabilities', () {
      const input = AgentInput(
        text: 'Hello',
        chatId: 'group-1',
        senderId: 'user-1',
        isAdmin: false,
      );
      final prompt = buildSystemPrompt(input);

      expect(prompt, contains('nudge'));
      expect(prompt, contains('configure_standup'));
    });

    test('mentions session facilitation capabilities', () {
      const input = AgentInput(
        text: 'Hello',
        chatId: 'group-1',
        senderId: 'user-1',
        isAdmin: false,
      );
      final prompt = buildSystemPrompt(input);

      expect(prompt, contains('start_session'));
      expect(prompt, contains('facilitat'));
    });

    test('mentions deep_search in capabilities', () {
      const input = AgentInput(
        text: 'Hello',
        chatId: 'group-1',
        senderId: 'user-1',
        isAdmin: false,
      );
      final prompt = buildSystemPrompt(input);

      expect(prompt, contains('deep_search'));
      expect(prompt, contains('search_memory'));
    });

    test('includes Retrieval Reasoning section', () {
      const input = AgentInput(
        text: 'Hello',
        chatId: 'group-1',
        senderId: 'user-1',
        isAdmin: false,
      );
      final prompt = buildSystemPrompt(input);

      expect(prompt, contains('## Retrieval Reasoning'));
      expect(prompt, contains('passive recall'));
      expect(prompt, contains('Evaluate'));
    });

    test('includes Proactive Scan section when isProactive is true', () {
      const input = AgentInput(
        text: 'Scan for tasks',
        chatId: 'group-1',
        senderId: 'system',
        isAdmin: true,
        isProactive: true,
      );
      final prompt = buildSystemPrompt(input);

      expect(prompt, contains('## Proactive Scan'));
      expect(prompt, contains('full tool access'));
      expect(prompt, contains('reference actual cards'));
      // Should NOT include the system-initiated reminder (no tools).
      expect(prompt, isNot(contains('## System-Initiated Reminder')));
      expect(prompt, isNot(contains('Do not use tools.')));
    });

    test('isProactive takes precedence over isSystemInitiated', () {
      const input = AgentInput(
        text: 'Scan for tasks',
        chatId: 'group-1',
        senderId: 'system',
        isAdmin: true,
        isProactive: true,
        isSystemInitiated: true,
      );
      final prompt = buildSystemPrompt(input);

      // Proactive wins — should see scan section, not system-initiated.
      expect(prompt, contains('## Proactive Scan'));
      expect(prompt, isNot(contains('## System-Initiated Reminder')));
    });

    test('defaults isProactive to false', () {
      const input = AgentInput(
        text: 'Hello',
        chatId: 'group-1',
        senderId: 'user-1',
        isAdmin: false,
      );
      final prompt = buildSystemPrompt(input);

      expect(prompt, isNot(contains('## Proactive Scan')));
    });

    test('includes personality trait proportions in Voice section', () {
      const input = AgentInput(
        text: 'Hello',
        chatId: 'group-1',
        senderId: 'user-1',
        isAdmin: false,
      );
      final prompt = buildSystemPrompt(
        input,
        identity: const BotIdentityRecord(
          id: 1,
          name: 'River',
          pronouns: 'they/them',
          tone: 'sardonic',
          toneDescription: 'Pub-register wit',
          chosenAt: '2026-04-16',
        ),
        personalityTraits: const [
          PersonalityTrait(name: 'directness', value: 85),
          PersonalityTrait(name: 'warmth', value: 30),
          PersonalityTrait(name: 'humor', value: 80),
          PersonalityTrait(name: 'formality', value: 10),
          PersonalityTrait(name: 'chaos', value: 60),
        ],
      );

      expect(prompt, contains('Directness: 85/100'));
      expect(prompt, contains('Warmth: 30/100'));
      expect(prompt, contains('Humor: 80/100'));
      expect(prompt, contains('Formality: 10/100'));
      expect(prompt, contains('Chaos: 60/100'));
      // Should still include the tone description as anchor text.
      expect(prompt, contains('Pub-register wit'));
    });

    test('falls back to static Voice when no traits provided', () {
      const input = AgentInput(
        text: 'Hello',
        chatId: 'group-1',
        senderId: 'user-1',
        isAdmin: false,
      );
      final prompt = buildSystemPrompt(
        input,
        identity: const BotIdentityRecord(
          id: 1,
          name: 'River',
          pronouns: 'they/them',
          tone: 'sardonic',
          toneDescription: 'Short, blunt, dry. Pub-register wit',
          chosenAt: '2026-04-16',
        ),
      );

      // V1 static voice — should contain the hardcoded pub-register paragraph.
      expect(prompt, contains('the guy at the pub three beers in'));
      // Should NOT contain trait proportions.
      expect(prompt, isNot(contains('/100')));
    });

    test('naming ceremony prompt describes dial mode', () {
      const input = AgentInput(
        text: 'naming ceremony',
        chatId: 'group-1',
        senderId: 'user-1',
        isAdmin: true,
      );
      final prompt = buildSystemPrompt(input);

      expect(prompt, contains('personality trait'));
      expect(prompt, contains('proportions'));
    });
  });
}
