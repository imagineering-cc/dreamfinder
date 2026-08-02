import 'package:dreamfinder/src/kickstart/kickstart_prompt.dart';
import 'package:dreamfinder/src/kickstart/kickstart_state.dart';
import 'package:dreamfinder/src/session/session_prompt.dart';
import 'package:dreamfinder/src/session/session_state.dart';
import 'package:test/test.dart';

/// Retired MCP tool names — after the Kan/Outline MCP→CLI migration (#100/#114)
/// only `run_cli` exists. Any of these in a live prompt is a silent-failure
/// regression (kickstart triggers but its guided step calls a dead tool).
const _retiredMcpToolNames = <String>[
  'kan_list_workspaces',
  'kan_list_boards',
  'kan_search',
  'kan_create_card',
  'kan_create_list',
  'outline_create_document',
  'outline_search',
];

void main() {
  const groupId = 'test-group-id';

  // The invariant, guarded across the WHOLE prompt corpus (every kickstart
  // step AND every session phase), so a retired name can't sneak back into any
  // untested section.
  group('no retired MCP tool names in any guided prompt', () {
    for (final step in KickstartStep.values) {
      test('kickstart ${step.name} uses run_cli, not retired MCP names', () {
        final section = buildKickstartPromptSection(step, groupId);
        for (final retired in _retiredMcpToolNames) {
          expect(section, isNot(contains(retired)),
              reason: '$retired is a dead tool; use run_cli');
        }
      });
    }
    for (final phase in SessionPhase.values) {
      test('session ${phase.name} uses run_cli, not retired MCP names', () {
        final section = buildSessionPromptSection(phase, groupId);
        for (final retired in _retiredMcpToolNames) {
          expect(section, isNot(contains(retired)),
              reason: '$retired is a dead tool; use run_cli');
        }
      });
    }
  });

  group('buildKickstartPromptSection', () {
    test('workspace step includes step header', () {
      final section = buildKickstartPromptSection(
        KickstartStep.workspace,
        groupId,
      );
      expect(section, contains('Step 1 of 6: Workspace Setup'));
    });

    test('workspace step mentions get_chat_config tool', () {
      final section = buildKickstartPromptSection(
        KickstartStep.workspace,
        groupId,
      );
      expect(section, contains('get_chat_config'));
      expect(section, contains('run_cli'));
      expect(section, contains('list-workspaces'));
    });

    test('workspace step includes advance instruction', () {
      final section = buildKickstartPromptSection(
        KickstartStep.workspace,
        groupId,
      );
      expect(section, contains('advance_kickstart'));
      expect(section, contains(groupId));
    });

    test('meet and greet step drives contacts via the radicale CLI', () {
      final section = buildKickstartPromptSection(
        KickstartStep.meetAndGreet,
        groupId,
      );
      expect(section, contains('Step 2 of 6: Meet & Greet'));
      // Driven through run_cli (tool: radicale), NOT the retired MCP tools.
      expect(section, contains('run_cli'));
      expect(section, contains('add-contact'));
      expect(section, contains('list-address-books'));
      expect(section, contains(kickstartAddressBook));
      // The old MCP tool names must be gone.
      expect(section, isNot(contains('radicale_create_contact')));
      expect(section, isNot(contains('radicale_list_address_books')));
    });

    test('meet and greet asks about timezone and role', () {
      final section = buildKickstartPromptSection(
        KickstartStep.meetAndGreet,
        groupId,
      );
      expect(section, contains('timezone'));
      expect(section, contains('role'));
    });

    test('meet and greet has warm conversational tone guidance', () {
      final section = buildKickstartPromptSection(
        KickstartStep.meetAndGreet,
        groupId,
      );
      // Round-the-room framing: each person introduces themselves, warm vibe,
      // not an interrogation.
      expect(section, contains('round of intros'));
      expect(section, contains('not a form'));
    });

    test('roster step mentions user mapping tools', () {
      final section = buildKickstartPromptSection(
        KickstartStep.roster,
        groupId,
      );
      expect(section, contains('Step 3 of 6: Team Roster'));
      expect(section, contains('list_user_mappings'));
      expect(section, contains('set_user_mapping'));
    });

    test('projects step mentions kan and outline tools', () {
      final section = buildKickstartPromptSection(
        KickstartStep.projects,
        groupId,
      );
      expect(section, contains('Step 4 of 6: Project Seeding'));
      expect(section, contains('run_cli'));
      expect(section, contains('search'));
      expect(section, contains('create-card'));
      expect(section, contains('documents.create'));
      // Guard against the retired MCP tool names regressing back in.
      expect(section, isNot(contains('kan_create_card')));
      expect(section, isNot(contains('outline_create_document')));
    });

    test('knowledge step mentions save_memory', () {
      final section = buildKickstartPromptSection(
        KickstartStep.knowledge,
        groupId,
      );
      expect(section, contains('Step 5 of 6: Knowledge Dump'));
      expect(section, contains('save_memory'));
      expect(section, contains('documents.create'));
      expect(section, isNot(contains('outline_create_document')));
    });

    test('primer step mentions complete_kickstart instead of advance', () {
      final section = buildKickstartPromptSection(
        KickstartStep.primer,
        groupId,
      );
      expect(section, contains('Step 6 of 6: Dream Primer'));
      expect(section, contains('complete_kickstart'));
      // Primer should NOT have advance instruction.
      expect(section, isNot(contains('advance_kickstart')));
    });

    test('primer step mentions dream cycle', () {
      final section = buildKickstartPromptSection(
        KickstartStep.primer,
        groupId,
      );
      expect(section, contains('dream cycle'));
    });

    test('primer step mentions user profile in summary', () {
      final section = buildKickstartPromptSection(
        KickstartStep.primer,
        groupId,
      );
      expect(section, contains('profile'));
    });

    test('all steps include guided conversation note', () {
      for (final step in KickstartStep.values) {
        final section = buildKickstartPromptSection(step, groupId);
        expect(section, contains('guided conversation'));
      }
    });

    test('header frames setup as in-room, not DM', () {
      final section = buildKickstartPromptSection(
        KickstartStep.workspace,
        groupId,
      );
      expect(section, contains('in their group room'));
      expect(section, isNot(contains('via DM')));
    });

    test('primer step mentions post_kickstart_summary', () {
      final section = buildKickstartPromptSection(
        KickstartStep.primer,
        groupId,
      );
      expect(section, contains('post_kickstart_summary'));
    });

    test('all non-primer steps mention skip/done advancement', () {
      for (final step in KickstartStep.values) {
        if (step == KickstartStep.primer) continue;
        final section = buildKickstartPromptSection(step, groupId);
        expect(section, contains('"skip"'));
        expect(section, contains('"done"'));
      }
    });

    test('includes the group ID in tool call instructions', () {
      for (final step in KickstartStep.values) {
        final section = buildKickstartPromptSection(step, groupId);
        expect(section, contains(groupId));
      }
    });
  });
}
