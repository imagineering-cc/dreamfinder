import 'package:dreamfinder/src/db/message_repository.dart';
import 'package:dreamfinder/src/db/schema.dart';
import 'package:dreamfinder/src/dream/dream_prompt.dart';
import 'package:test/test.dart';

void main() {
  const defaultContext = DreamContext(
    botName: 'Dreamfinder',
    groupId: 'group-1',
  );

  group('buildDreamCyclePrompt', () {
    test('light cycle includes triage instructions', () {
      final prompt = buildDreamCyclePrompt(
        context: defaultContext,
        cycle: SleepCycle.light,
        chatHistory: [],
      );

      expect(prompt, contains('Light Sleep'));
      expect(prompt, contains('N1→N2'));
      expect(prompt, contains('Stage N1'));
      expect(prompt, contains('Triage'));
      expect(prompt, contains('overdue'));
      expect(prompt, contains('Stage N2'));
      expect(prompt, contains('File'));
      expect(prompt, contains('Do NOT send messages to chat rooms'));
    });

    test('deep cycle outputs task format instructions', () {
      final prompt = buildDreamCyclePrompt(
        context: defaultContext,
        cycle: SleepCycle.deep,
        chatHistory: [],
        previousSummaries: ['Filed 3 items.'],
      );

      expect(prompt, contains('Deep Sleep'));
      expect(prompt, contains('N2→N3'));
      expect(prompt, contains('Restore'));
      expect(prompt, contains('[TASK:'));
      // Should include previous summary.
      expect(prompt, contains('Filed 3 items.'));
    });

    test('uses custom identity', () {
      final prompt = buildDreamCyclePrompt(
        context: DreamContext(
          botName: 'Dreamfinder',
          groupId: 'group-1',
          identity: const BotIdentityRecord(
            id: 1,
            name: 'Figment',
            pronouns: 'he/him',
            tone: 'whimsical',
            toneDescription: 'Whimsical and curious',
            chosenAt: '2026-03-14',
          ),
        ),
        cycle: SleepCycle.light,
        chatHistory: [],
      );

      expect(prompt, contains('Figment'));
      expect(prompt, contains('he/him'));
      expect(prompt, contains('Whimsical and curious'));
    });

    test('formats chat history and skips tool-result blocks', () {
      final messages = [
        const PersistedMessage(
          id: 1,
          chatId: 'group-1',
          role: MessageRole.user,
          content: 'Design review?',
          senderUuid: 'uuid-alice',
          senderName: 'Alice',
          createdAt: '2026-03-14T10:00:00',
        ),
        PersistedMessage(
          id: 2,
          chatId: 'group-1',
          role: MessageRole.user,
          content: <Map<String, dynamic>>[
            {'toolUseId': 't1', 'content': '{}'},
          ],
          createdAt: '2026-03-14T10:01:00',
        ),
        const PersistedMessage(
          id: 3,
          chatId: 'group-1',
          role: MessageRole.assistant,
          content: 'Card created!',
          createdAt: '2026-03-14T10:02:00',
        ),
      ];

      final prompt = buildDreamCyclePrompt(
        context: defaultContext,
        cycle: SleepCycle.light,
        chatHistory: messages,
      );

      expect(prompt, contains('[Alice] Design review?'));
      expect(prompt, contains('[Dreamfinder] Card created!'));
      expect(prompt, isNot(contains('toolUseId')));
    });
  });

  group('buildDreamBranchPrompt', () {
    test('includes task and branch number', () {
      final prompt = buildDreamBranchPrompt(
        context: defaultContext,
        task: const DreamTask(
          DreamTaskType.review,
          'Auth refactor shares session logic with onboarding',
        ),
        branchNumber: 1,
        totalBranches: 3,
        deepSummary: 'Found 3 connections.',
      );

      expect(prompt, contains('Dream Branch 1 of 3'));
      expect(prompt, contains('Auth refactor shares session logic'));
      expect(prompt, contains('Found 3 connections.'));
      expect(prompt, contains('N3 (Restore)'));
      expect(prompt, contains('dream::group-1::branch-1'));
    });

    test('instructs agent to focus on single task', () {
      final prompt = buildDreamBranchPrompt(
        context: defaultContext,
        task: const DreamTask(DreamTaskType.nudge, 'Test task'),
        branchNumber: 2,
        totalBranches: 2,
        deepSummary: 'Summary.',
      );

      expect(prompt, contains('no awareness of any other dream threads'));
      expect(prompt, contains('Do NOT work on other tasks'));
    });

    test('includes task-type-specific instructions for triage', () {
      final prompt = buildDreamBranchPrompt(
        context: defaultContext,
        task: const DreamTask(
          DreamTaskType.triage,
          'Update overdue cards on the Sprint board',
        ),
        branchNumber: 1,
        totalBranches: 1,
        deepSummary: 'Summary.',
      );

      expect(prompt, contains('overdue'));
      expect(prompt, contains('status'));
    });

    test('includes task-type-specific instructions for prep', () {
      final prompt = buildDreamBranchPrompt(
        context: defaultContext,
        task: const DreamTask(
          DreamTaskType.prep,
          'Prepare for tomorrow standup meeting',
        ),
        branchNumber: 1,
        totalBranches: 1,
        deepSummary: 'Summary.',
      );

      expect(prompt, contains('agenda'));
    });

    test('includes task-type-specific instructions for draft', () {
      final prompt = buildDreamBranchPrompt(
        context: defaultContext,
        task: const DreamTask(
          DreamTaskType.draft,
          'Write weekly progress summary',
        ),
        branchNumber: 1,
        totalBranches: 1,
        deepSummary: 'Summary.',
      );

      expect(prompt, contains('Outline'));
    });
  });

  group('buildDreamConvergencePrompt', () {
    test('includes all branch reports', () {
      final prompt = buildDreamConvergencePrompt(
        context: defaultContext,
        branchReports: [
          'Explored auth: created doc.',
          'Explored calendar: updated cards.',
        ],
        deepSummary: 'Deep findings.',
      );

      expect(prompt, contains('Stage REM'));
      expect(prompt, contains('Dream Thread 1'));
      expect(prompt, contains('Dream Thread 2'));
      expect(prompt, contains('Explored auth: created doc.'));
      expect(prompt, contains('Explored calendar: updated cards.'));
      expect(prompt, contains('Deep findings.'));
      expect(prompt, contains('morning briefing'));
      expect(prompt, contains('dream::group-1::rem'));
    });

    test('mentions number of threads explored', () {
      final prompt = buildDreamConvergencePrompt(
        context: defaultContext,
        branchReports: ['A', 'B', 'C'],
        deepSummary: 'Summary.',
      );

      expect(prompt, contains('3 tasks'));
    });

    test('includes morning briefing instructions', () {
      final prompt = buildDreamConvergencePrompt(
        context: defaultContext,
        branchReports: ['Done A.'],
        deepSummary: 'Summary.',
      );

      expect(prompt, contains('morning briefing'));
      expect(prompt, contains('Do NOT send messages to chat rooms'));
    });
  });

  group('parseTasks', () {
    test('extracts typed task lines', () {
      final tasks = parseTasks(
        'Found work to do.\n'
        '[TASK:triage] Update overdue cards on Sprint board\n'
        '[TASK:prep] Prepare for tomorrow standup meeting\n'
        'Summary done.',
      );

      expect(tasks, hasLength(2));
      expect(tasks[0].type, equals(DreamTaskType.triage));
      expect(tasks[0].description, equals('Update overdue cards on Sprint board'));
      expect(tasks[1].type, equals(DreamTaskType.prep));
      expect(tasks[1].description, equals('Prepare for tomorrow standup meeting'));
    });

    test('caps at maxDreamBranches', () {
      final tasks = parseTasks(
        '[TASK:triage] One\n[TASK:nudge] Two\n[TASK:draft] Three\n'
        '[TASK:review] Four\n[TASK:prep] Five\n[TASK:explore] Six\n',
      );

      expect(tasks, hasLength(maxDreamBranches));
    });

    test('returns empty list when no tasks', () {
      expect(parseTasks('Nothing to do tonight.'), isEmpty);
    });

    test('unknown type defaults to explore', () {
      final tasks = parseTasks('[TASK:banana] Something unusual');

      expect(tasks, hasLength(1));
      expect(tasks[0].type, equals(DreamTaskType.explore));
      expect(tasks[0].description, equals('Something unusual'));
    });

    test('handles all known task types', () {
      final tasks = parseTasks(
        '[TASK:triage] A\n'
        '[TASK:prep] B\n'
        '[TASK:draft] C\n'
        '[TASK:nudge] D\n',
      );

      expect(tasks[0].type, equals(DreamTaskType.triage));
      expect(tasks[1].type, equals(DreamTaskType.prep));
      expect(tasks[2].type, equals(DreamTaskType.draft));
      expect(tasks[3].type, equals(DreamTaskType.nudge));
    });
  });

  group('parseDepthSignal', () {
    test('parses continue', () {
      expect(
        parseDepthSignal('Filed. [DEPTH: continue]',
            defaultSignal: DepthSignal.wake),
        equals(DepthSignal.continue_),
      );
    });

    test('parses wake', () {
      expect(
        parseDepthSignal('Done. [DEPTH: wake]',
            defaultSignal: DepthSignal.continue_),
        equals(DepthSignal.wake),
      );
    });

    test('returns default when missing', () {
      expect(
        parseDepthSignal('No tag.', defaultSignal: DepthSignal.continue_),
        equals(DepthSignal.continue_),
      );
    });
  });

  group('stripDepthSignal', () {
    test('removes tag', () {
      expect(stripDepthSignal('Filed. [DEPTH: continue]'), equals('Filed.'));
    });

    test('handles no tag', () {
      expect(stripDepthSignal('Just text.'), equals('Just text.'));
    });
  });
}
