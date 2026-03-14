import 'package:dreamfinder/src/kickstart/kickstart_prompt.dart';
import 'package:dreamfinder/src/kickstart/kickstart_state.dart';
import 'package:test/test.dart';

void main() {
  const groupId = 'test-group-id';

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
      expect(section, contains('kan_list_workspaces'));
    });

    test('workspace step includes advance instruction', () {
      final section = buildKickstartPromptSection(
        KickstartStep.workspace,
        groupId,
      );
      expect(section, contains('advance_kickstart'));
      expect(section, contains(groupId));
    });

    test('meet and greet step mentions radicale tools', () {
      final section = buildKickstartPromptSection(
        KickstartStep.meetAndGreet,
        groupId,
      );
      expect(section, contains('Step 2 of 6: Meet & Greet'));
      expect(section, contains('radicale_create_contact'));
      expect(section, contains('radicale_list_address_books'));
      expect(section, contains(kickstartAddressBook));
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
      expect(section, contains('coffee chat'));
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
      expect(section, contains('kan_search'));
      expect(section, contains('kan_create_card'));
      expect(section, contains('outline_create_document'));
    });

    test('knowledge step mentions save_memory', () {
      final section = buildKickstartPromptSection(
        KickstartStep.knowledge,
        groupId,
      );
      expect(section, contains('Step 5 of 6: Knowledge Dump'));
      expect(section, contains('save_memory'));
      expect(section, contains('outline_create_document'));
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

    test('header mentions DM-based setup', () {
      final section = buildKickstartPromptSection(
        KickstartStep.workspace,
        groupId,
      );
      expect(section, contains('via DM'));
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
