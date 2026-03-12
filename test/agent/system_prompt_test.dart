import 'package:dreamfinder/src/agent/agent_loop.dart';
import 'package:dreamfinder/src/agent/system_prompt.dart';
import 'package:dreamfinder/src/memory/memory_record.dart';
import 'package:test/test.dart';

void main() {
  group('buildSystemPrompt', () {
    test('includes System-Initiated Reminder section when flag is true', () {
      const input = AgentInput(
        text: 'Send standup prompt',
        chatId: 'group-1',
        senderUuid: 'system',
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
        senderUuid: 'user-1',
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
        senderUuid: 'user-1',
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
        senderUuid: 'user-1',
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
        senderUuid: 'user-1',
        isAdmin: false,
      );
      final prompt = buildSystemPrompt(input);
      expect(prompt, isNot(contains('Relevant Memories')));
    });

    test('defaults isSystemInitiated to false', () {
      const input = AgentInput(
        text: 'Hello',
        chatId: 'group-1',
        senderUuid: 'user-1',
        isAdmin: false,
      );
      final prompt = buildSystemPrompt(input);

      expect(prompt, contains('Requesting user:'));
      expect(prompt, isNot(contains('System-Initiated Reminder')));
    });
  });
}
