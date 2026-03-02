import 'package:imagineering_pm_bot/src/meetup/meetup_config.dart';
import 'package:imagineering_pm_bot/src/meetup/meetup_session.dart';
import 'package:test/test.dart';

void main() {
  late MeetupConfig config;

  setUp(() {
    config = const MeetupConfig(
      meetLink: 'https://meet.google.com/test',
      participants: ['Alice', 'Bob', 'Charlie'],
    );
  });

  group('MeetupPhase', () {
    test('isSprint returns true only for sprint phases', () {
      expect(MeetupPhase.sprint1.isSprint, isTrue);
      expect(MeetupPhase.sprint2.isSprint, isTrue);
      expect(MeetupPhase.sprint3.isSprint, isTrue);
      expect(MeetupPhase.break1.isSprint, isFalse);
      expect(MeetupPhase.intros.isSprint, isFalse);
      expect(MeetupPhase.idle.isSprint, isFalse);
    });

    test('isBreak returns true only for break phases', () {
      expect(MeetupPhase.break1.isBreak, isTrue);
      expect(MeetupPhase.break2.isBreak, isTrue);
      expect(MeetupPhase.break3.isBreak, isTrue);
      expect(MeetupPhase.sprint1.isBreak, isFalse);
      expect(MeetupPhase.intros.isBreak, isFalse);
    });

    test('isActive is true for all phases except idle and done', () {
      expect(MeetupPhase.idle.isActive, isFalse);
      expect(MeetupPhase.done.isActive, isFalse);
      for (final phase in MeetupPhase.values) {
        if (phase != MeetupPhase.idle && phase != MeetupPhase.done) {
          expect(phase.isActive, isTrue, reason: '$phase should be active');
        }
      }
    });

    test('next returns the following phase in sequence', () {
      expect(MeetupPhase.idle.next, MeetupPhase.intros);
      expect(MeetupPhase.intros.next, MeetupPhase.sprint1);
      expect(MeetupPhase.sprint1.next, MeetupPhase.break1);
      expect(MeetupPhase.break1.next, MeetupPhase.sprint2);
      expect(MeetupPhase.sprint2.next, MeetupPhase.break2);
      expect(MeetupPhase.break2.next, MeetupPhase.sprint3);
      expect(MeetupPhase.sprint3.next, MeetupPhase.break3);
      expect(MeetupPhase.break3.next, MeetupPhase.demos);
      expect(MeetupPhase.demos.next, MeetupPhase.done);
      expect(MeetupPhase.done.next, isNull);
    });
  });

  group('MeetupSession', () {
    test('starts in idle phase', () {
      final session = MeetupSession(config: config);
      expect(session.phase, MeetupPhase.idle);
      expect(session.phaseStartedAt, isNull);
    });

    test('start() transitions from idle to intros', () {
      final session = MeetupSession(config: config);
      final now = DateTime(2026, 3, 28, 10, 0);

      session.start(now);

      expect(session.phase, MeetupPhase.intros);
      expect(session.phaseStartedAt, now);
    });

    test('start() throws if already started', () {
      final session = MeetupSession(config: config);
      session.start(DateTime(2026, 3, 28, 10, 0));

      expect(
        () => session.start(DateTime(2026, 3, 28, 10, 1)),
        throwsStateError,
      );
    });

    test('advance() moves through phases in order', () {
      final session = MeetupSession(config: config);
      final now = DateTime(2026, 3, 28, 10, 0);
      session.start(now);

      expect(session.advance(now), MeetupPhase.sprint1);
      expect(session.advance(now), MeetupPhase.break1);
      expect(session.advance(now), MeetupPhase.sprint2);
      expect(session.advance(now), MeetupPhase.break2);
      expect(session.advance(now), MeetupPhase.sprint3);
      expect(session.advance(now), MeetupPhase.break3);
      expect(session.advance(now), MeetupPhase.demos);
      expect(session.advance(now), MeetupPhase.done);
    });

    test('advance() throws when session is complete', () {
      final session = MeetupSession(config: config);
      final now = DateTime(2026, 3, 28, 10, 0);
      session.start(now);

      // Advance through all phases to done.
      while (session.phase != MeetupPhase.done) {
        session.advance(now);
      }

      expect(() => session.advance(now), throwsStateError);
    });

    test('advance() throws when session not started', () {
      final session = MeetupSession(config: config);

      expect(
        () => session.advance(DateTime(2026, 3, 28, 10, 0)),
        throwsStateError,
      );
    });

    test('elapsed() returns time since phase started', () {
      final session = MeetupSession(config: config);
      final start = DateTime(2026, 3, 28, 10, 0);
      session.start(start);

      final later = start.add(const Duration(minutes: 2, seconds: 30));
      expect(session.elapsed(later), const Duration(minutes: 2, seconds: 30));
    });

    test('elapsed() returns zero when idle', () {
      final session = MeetupSession(config: config);
      expect(session.elapsed(DateTime.now()), Duration.zero);
    });

    test('remaining() returns time left in current phase', () {
      final session = MeetupSession(config: config);
      final start = DateTime(2026, 3, 28, 10, 0);
      session.start(start);

      // Intros phase is 5 minutes. 2 minutes in -> 3 minutes remaining.
      final later = start.add(const Duration(minutes: 2));
      expect(session.remaining(later), const Duration(minutes: 3));
    });

    test('remaining() clamps to zero when time exceeded', () {
      final session = MeetupSession(config: config);
      final start = DateTime(2026, 3, 28, 10, 0);
      session.start(start);

      // 10 minutes into a 5-minute intros phase.
      final later = start.add(const Duration(minutes: 10));
      expect(session.remaining(later), Duration.zero);
    });

    test('phaseDuration returns correct durations', () {
      final session = MeetupSession(config: config);

      expect(
        session.phaseDuration(MeetupPhase.intros),
        const Duration(minutes: 5),
      );
      expect(
        session.phaseDuration(MeetupPhase.sprint1),
        const Duration(minutes: 25),
      );
      expect(
        session.phaseDuration(MeetupPhase.break1),
        const Duration(minutes: 10),
      );
      expect(
        session.phaseDuration(MeetupPhase.demos),
        const Duration(minutes: 5),
      );
      expect(session.phaseDuration(MeetupPhase.idle), Duration.zero);
      expect(session.phaseDuration(MeetupPhase.done), Duration.zero);
    });

    test('isPhaseExpired returns true when time is up', () {
      final session = MeetupSession(config: config);
      final start = DateTime(2026, 3, 28, 10, 0);
      session.start(start);

      // Not expired yet.
      expect(
        session.isPhaseExpired(start.add(const Duration(minutes: 3))),
        isFalse,
      );

      // Exactly at the boundary.
      expect(
        session.isPhaseExpired(start.add(const Duration(minutes: 5))),
        isTrue,
      );

      // Past the boundary.
      expect(
        session.isPhaseExpired(start.add(const Duration(minutes: 6))),
        isTrue,
      );
    });

    test('isPhaseExpired returns false when idle or done', () {
      final session = MeetupSession(config: config);
      expect(session.isPhaseExpired(DateTime.now()), isFalse);

      // Advance to done.
      final now = DateTime(2026, 3, 28, 10, 0);
      session.start(now);
      while (session.phase != MeetupPhase.done) {
        session.advance(now);
      }
      expect(session.isPhaseExpired(now), isFalse);
    });

    test('full session progresses through all phases', () {
      final session = MeetupSession(config: config);
      final start = DateTime(2026, 3, 28, 10, 0);
      session.start(start);

      final expectedPhases = [
        MeetupPhase.sprint1,
        MeetupPhase.break1,
        MeetupPhase.sprint2,
        MeetupPhase.break2,
        MeetupPhase.sprint3,
        MeetupPhase.break3,
        MeetupPhase.demos,
        MeetupPhase.done,
      ];

      for (final expected in expectedPhases) {
        final actual = session.advance(start);
        expect(actual, expected);
      }
    });
  });
}
