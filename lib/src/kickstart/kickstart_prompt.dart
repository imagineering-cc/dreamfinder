/// Kickstart prompt builder — generates system prompt sections for each step.
///
/// Each step injects specific instructions into the normal system prompt,
/// telling the agent what to do, which tools to use, and how to detect
/// when the user is ready to advance.
library;

import 'kickstart_state.dart';

/// Builds a system prompt section for the active kickstart step.
///
/// This section is appended to the normal system prompt when a kickstart is
/// active. It provides step-specific guidance for the agent, including which
/// tools to use and how to detect when to advance.
String buildKickstartPromptSection(KickstartStep step, String groupId) {
  final header = '\n## Kickstart — Step ${step.number} of 5: ${step.label}\n\n'
      'You are guiding this user through setup via DM. '
      'The group\'s `signal_group_id` is `$groupId` — use it for all tool calls. '
      'This is a guided conversation — ask questions, use tools, '
      'and advance when the step is complete.\n\n';

  final advanceNote = '\n\n**Advancing**: When this step is complete, call the '
      '`advance_kickstart` tool with `signal_group_id` set to `$groupId`. '
      'If the user says "skip", "next", or "done", treat the step as complete '
      'and advance.\n';

  final completeNote = '\n\n**Completing**: When you finish the primer, call the '
      '`complete_kickstart` tool with `signal_group_id` set to `$groupId` '
      'to mark onboarding as done. Then compose a summary of everything that '
      'was set up and call `post_kickstart_summary` with `signal_group_id` '
      'set to `$groupId` and the summary text to announce it to the group.\n';

  final body = switch (step) {
    KickstartStep.workspace => _workspacePrompt(groupId),
    KickstartStep.roster => _rosterPrompt(groupId),
    KickstartStep.projects => _projectsPrompt(groupId),
    KickstartStep.knowledge => _knowledgePrompt(groupId),
    KickstartStep.primer => _primerPrompt(groupId),
  };

  final footer = step == KickstartStep.primer ? completeNote : advanceNote;

  return '$header$body$footer';
}

String _workspacePrompt(String groupId) => '''
**Goal**: Ensure this group has a linked Kan workspace and default board.

**Steps**:
1. Call `get_chat_config` with `signal_group_id` = `$groupId` to check if a workspace is already linked.
2. If no workspace is linked:
   - Call `kan_list_workspaces` to show available workspaces.
   - Ask the user which workspace to link.
   - Call `set_chat_config` to link it.
3. If a workspace is linked but no default board:
   - Call `kan_list_boards` to show available boards in the workspace.
   - Ask the user which board to use as the default.
   - Call `set_chat_config` to set the default board.
4. If both are set, confirm and advance.

**Tools**: `get_chat_config`, `set_chat_config`, `kan_list_workspaces`, `kan_list_boards`''';

String _rosterPrompt(String groupId) => '''
**Goal**: Map Signal users to Kan workspace members.

**Steps**:
1. Call `list_user_mappings` with `signal_group_id` = `$groupId` to see existing mappings.
2. Ask the user about team members in this group:
   - "Who's on the team? I can map Signal users to their Kan accounts."
3. For each team member the user mentions, use `set_user_mapping` to create the mapping.
4. When the user says they're done (or says "done", "next", "skip"), advance.

**Tools**: `list_user_mappings`, `set_user_mapping`''';

String _projectsPrompt(String groupId) => '''
**Goal**: Seed the Kan board with the team's active projects.

**Steps**:
1. Ask: "Tell me about your active projects — what's the team working on right now?"
2. For each project the user describes:
   - Search Kan for existing cards: `kan_search` with the project name.
   - If no card exists, create one: `kan_create_card` on the default board.
   - Create an Outline doc for the project: `outline_create_document`.
3. Summarize what was created after each project.
4. When the user says they're done (or says "done", "next", "skip"), advance.

**Tools**: `kan_search`, `kan_create_card`, `kan_create_list`, `outline_create_document`, `outline_search`''';

String _knowledgePrompt(String groupId) => '''
**Goal**: Capture recent decisions, context, and institutional knowledge.

**Steps**:
1. Ask: "Any recent decisions, conventions, or context I should know about? Things like coding standards, deployment processes, or recent architectural decisions."
2. For each piece of knowledge the user shares:
   - File it as an Outline document: `outline_create_document`.
   - Save key facts to memory: `save_memory` with `visibility` = `cross_chat`.
3. When the user says they're done (or says "done", "next", "skip"), advance.

**Tools**: `outline_create_document`, `outline_search`, `save_memory`''';

String _primerPrompt(String groupId) => '''
**Goal**: Summarize what was set up and introduce the dream cycle.

**Steps**:
1. Summarize everything that was configured during kickstart:
   - Workspace and board linkage
   - Team member mappings
   - Projects seeded
   - Knowledge captured
2. Explain the dream cycle in character:
   - "When someone says goodnight, I enter a dream cycle — reviewing the day's conversations, organizing knowledge, and surfacing connections."
   - Keep it brief and in-character, like sharing a secret about how you work.
3. Invite the team to say goodnight when they're ready for their first dream.
4. Call `complete_kickstart` to finish onboarding.

**Tools**: `complete_kickstart`, `post_kickstart_summary`''';
