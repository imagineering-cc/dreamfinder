import 'package:dreamfinder/src/session/session_prompt.dart';
import 'package:dreamfinder/src/session/session_state.dart';
import 'package:test/test.dart';

void main() {
  const groupId = 'test-group-id';

  group('buildSessionPromptSection', () {
    test('each phase produces a non-empty string', () {
      for (final phase in SessionPhase.values) {
        final section = buildSessionPromptSection(phase, groupId);
        expect(section, isNotEmpty,
            reason: '${phase.label} should not be empty');
      }
    });

    test('pitch phase mentions facilitation or introductions', () {
      final section = buildSessionPromptSection(SessionPhase.pitch, groupId);
      expect(
        section.contains('facilitat') || section.contains('introduc'),
        isTrue,
        reason: 'Pitch phase should mention facilitation or introductions',
      );
    });

    test('build phases mention quiet or focused', () {
      for (final phase in [
        SessionPhase.build1,
        SessionPhase.build2,
        SessionPhase.build3,
      ]) {
        final section = buildSessionPromptSection(phase, groupId);
        expect(
          section.contains('quiet') || section.contains('focus'),
          isTrue,
          reason: '${phase.label} should mention quiet or focused work',
        );
      }
    });

    test('chat phases mention check-in or facilitation', () {
      for (final phase in [
        SessionPhase.chat1,
        SessionPhase.chat2,
        SessionPhase.chat3,
      ]) {
        final section = buildSessionPromptSection(phase, groupId);
        expect(
          section.contains('check') || section.contains('facilitat'),
          isTrue,
          reason: '${phase.label} should mention check-in or facilitation',
        );
      }
    });

    test('demo phase mentions summary or celebration', () {
      final section = buildSessionPromptSection(SessionPhase.demo, groupId);
      expect(
        section.contains('summar') || section.contains('celebrat'),
        isTrue,
        reason: 'Demo phase should mention summary or celebration',
      );
    });

    test('all phases include the groupId', () {
      for (final phase in SessionPhase.values) {
        final section = buildSessionPromptSection(phase, groupId);
        expect(section, contains(groupId),
            reason: '${phase.label} should include groupId');
      }
    });

    test('non-demo phases mention advance_session', () {
      for (final phase in SessionPhase.values) {
        if (phase == SessionPhase.demo) continue;
        final section = buildSessionPromptSection(phase, groupId);
        expect(section, contains('advance_session'),
            reason: '${phase.label} should mention advance_session');
      }
    });

    test('demo phase mentions end_session', () {
      final section = buildSessionPromptSection(SessionPhase.demo, groupId);
      expect(section, contains('end_session'));
    });

    test('demo phase does not mention advance_session', () {
      final section = buildSessionPromptSection(SessionPhase.demo, groupId);
      expect(section, isNot(contains('advance_session')));
    });
  });
}
