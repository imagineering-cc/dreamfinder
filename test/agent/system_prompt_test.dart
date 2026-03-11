import 'package:dreamfinder/src/agent/agent_loop.dart';
import 'package:dreamfinder/src/agent/system_prompt.dart';
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
