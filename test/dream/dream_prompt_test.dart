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
    test('light cycle includes N1 and N2 stages', () {
      final prompt = buildDreamCyclePrompt(
        context: defaultContext,
        cycle: SleepCycle.light,
        chatHistory: [],
      );

      expect(prompt, contains('Light Sleep'));
      expect(prompt, contains('N1→N2'));
      expect(prompt, contains('Stage N1'));
      expect(prompt, contains('Drift'));
      expect(prompt, contains('Stage N2'));
      expect(prompt, contains('Settle'));
      expect(prompt, contains('Do NOT send any Signal messages'));
    });

    test('deep cycle outputs spark format instructions', () {
      final prompt = buildDreamCyclePrompt(
        context: defaultContext,
        cycle: SleepCycle.deep,
        chatHistory: [],
        previousSummaries: ['Filed 3 items.'],
      );

      expect(prompt, contains('Deep Sleep'));
      expect(prompt, contains('N2→N3'));
      expect(prompt, contains('Restore'));
      expect(prompt, contains('[SPARK]'));
      expect(prompt, contains('dream thread'));
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
    test('includes spark and branch number', () {
      final prompt = buildDreamBranchPrompt(
        context: defaultContext,
        spark: 'Auth refactor shares session logic with onboarding',
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

    test('instructs agent to focus on single spark', () {
      final prompt = buildDreamBranchPrompt(
        context: defaultContext,
        spark: 'Test spark',
        branchNumber: 2,
        totalBranches: 2,
        deepSummary: 'Summary.',
      );

      expect(prompt, contains('no awareness of any other dream threads'));
      expect(prompt, contains('Do NOT explore other sparks'));
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
      expect(prompt, contains('meta-patterns'));
      expect(prompt, contains('dream::group-1::rem'));
    });

    test('mentions number of threads explored', () {
      final prompt = buildDreamConvergencePrompt(
        context: defaultContext,
        branchReports: ['A', 'B', 'C'],
        deepSummary: 'Summary.',
      );

      expect(prompt, contains('3 sparks'));
    });
  });

  group('parseSparks', () {
    test('extracts spark lines', () {
      final sparks = parseSparks(
        'Found connections.\n'
        '[SPARK] Auth × onboarding session tokens\n'
        '[SPARK] Calendar timing overlap\n'
        'Summary done.',
      );

      expect(sparks, hasLength(2));
      expect(sparks[0], equals('Auth × onboarding session tokens'));
      expect(sparks[1], equals('Calendar timing overlap'));
    });

    test('caps at maxDreamBranches', () {
      final sparks = parseSparks(
        '[SPARK] One\n[SPARK] Two\n[SPARK] Three\n'
        '[SPARK] Four\n[SPARK] Five\n[SPARK] Six\n',
      );

      expect(sparks, hasLength(maxDreamBranches));
    });

    test('returns empty list when no sparks', () {
      expect(parseSparks('No sparks today.'), isEmpty);
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
