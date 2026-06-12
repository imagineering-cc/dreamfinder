import 'package:dreamfinder/src/agent/agent_loop.dart';
import 'package:dreamfinder/src/agent/system_prompt.dart';
import 'package:test/test.dart';

/// Pins the admin-salience fix (claude-tasks#662): River once refused a
/// legitimate admin because the senderName fallback rendered the literal
/// word "unknown", which outweighed the ADMIN tag in the model's reading.
/// The prompt must (a) never say "unknown" for a nameless sender, and
/// (b) state the ADMIN flag as mechanically verified.
void main() {
  group('buildSystemPrompt — admin salience', () {
    test('nameless admin renders sender ID and assertive ADMIN, no "unknown"',
        () {
      const input = AgentInput(
        text: 'please DM the new member',
        chatId: '!portal:test',
        senderId: '@signal_66eda24c:test',
        // senderName deliberately absent — the #662 incident shape.
        isAdmin: true,
      );
      final prompt = buildSystemPrompt(input);

      expect(prompt, contains('@signal_66eda24c:test'));
      expect(prompt, contains('ADMIN'));
      expect(prompt, contains('verified against the admin registry'));
      expect(prompt.toLowerCase(), isNot(contains('unknown')),
          reason: 'the word "unknown" reads as an authority verdict and '
              'must never appear in the sender line');
    });

    test('non-admin renders member wording with mechanical-rejection note', () {
      const input = AgentInput(
        text: 'hi',
        chatId: '!room:test',
        senderId: '@guest:test',
        senderName: 'Guest',
        isAdmin: false,
      );
      final prompt = buildSystemPrompt(input);

      expect(prompt, contains('member'));
      expect(prompt, contains('mechanically'));
      expect(prompt, isNot(contains('ADMIN —')));
    });
  });
}
