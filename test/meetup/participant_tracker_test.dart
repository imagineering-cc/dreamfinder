import 'package:imagineering_pm_bot/src/meetup/participant_tracker.dart';
import 'package:test/test.dart';

void main() {
  final t = DateTime(2026, 4, 25, 10, 0);

  group('ParticipantTracker', () {
    group('navigation', () {
      test('currentParticipant is the first participant', () {
        final tracker = ParticipantTracker(
          participants: ['Alice', 'Bob'],
          perPersonDuration: const Duration(seconds: 60),
        );

        expect(tracker.currentParticipant, 'Alice');
      });

      test('nextParticipant is the second participant', () {
        final tracker = ParticipantTracker(
          participants: ['Alice', 'Bob', 'Charlie'],
          perPersonDuration: const Duration(seconds: 60),
        );

        expect(tracker.nextParticipant, 'Bob');
      });

      test('nextParticipant is null for last participant', () {
        final tracker = ParticipantTracker(
          participants: ['Alice'],
          perPersonDuration: const Duration(seconds: 60),
        );

        expect(tracker.nextParticipant, isNull);
      });

      test('advance moves to next participant', () {
        final tracker = ParticipantTracker(
          participants: ['Alice', 'Bob', 'Charlie'],
          perPersonDuration: const Duration(seconds: 60),
        );
        tracker.startCurrentParticipant(t);

        tracker.advance(t.add(const Duration(seconds: 60)));

        expect(tracker.currentParticipant, 'Bob');
      });

      test('isComplete is false initially', () {
        final tracker = ParticipantTracker(
          participants: ['Alice'],
          perPersonDuration: const Duration(seconds: 60),
        );

        expect(tracker.isComplete, isFalse);
      });

      test('isComplete is true after advancing past last participant', () {
        final tracker = ParticipantTracker(
          participants: ['Alice'],
          perPersonDuration: const Duration(seconds: 60),
        );
        tracker.startCurrentParticipant(t);

        tracker.advance(t.add(const Duration(seconds: 60)));

        expect(tracker.isComplete, isTrue);
      });

      test('isComplete is true for empty participants', () {
        final tracker = ParticipantTracker(
          participants: [],
          perPersonDuration: const Duration(seconds: 60),
        );

        expect(tracker.isComplete, isTrue);
      });
    });

    group('elapsed', () {
      test('returns zero before startCurrentParticipant', () {
        final tracker = ParticipantTracker(
          participants: ['Alice'],
          perPersonDuration: const Duration(seconds: 60),
        );

        expect(tracker.elapsed(t), Duration.zero);
      });

      test('returns elapsed time after start', () {
        final tracker = ParticipantTracker(
          participants: ['Alice'],
          perPersonDuration: const Duration(seconds: 60),
        );
        tracker.startCurrentParticipant(t);

        expect(
          tracker.elapsed(t.add(const Duration(seconds: 30))),
          const Duration(seconds: 30),
        );
      });
    });

    group('check tiers', () {
      test('returns none before 75%', () {
        final tracker = ParticipantTracker(
          participants: ['Alice'],
          perPersonDuration: const Duration(seconds: 60),
        );
        tracker.startCurrentParticipant(t);

        // 44s = 73.3% < 75%
        final result = tracker.check(t.add(const Duration(seconds: 44)));

        expect(result.newTier, InterruptTier.none);
        expect(result.shouldAdvance, isFalse);
      });

      test('listenForPause at 75%', () {
        final tracker = ParticipantTracker(
          participants: ['Alice'],
          perPersonDuration: const Duration(seconds: 60),
        );
        tracker.startCurrentParticipant(t);

        // 45s = exactly 75%
        final result = tracker.check(t.add(const Duration(seconds: 45)));

        expect(result.newTier, InterruptTier.listenForPause);
        expect(result.participant, 'Alice');
        expect(result.shouldAdvance, isFalse);
      });

      test('warningSpoken at 92%', () {
        final tracker = ParticipantTracker(
          participants: ['Alice'],
          perPersonDuration: const Duration(seconds: 60),
        );
        tracker.startCurrentParticipant(t);

        // Trigger listenForPause first to clear it.
        tracker.check(t.add(const Duration(seconds: 45)));

        // 55.2s = 92% (use 56s > 92%)
        final result = tracker.check(t.add(const Duration(seconds: 56)));

        expect(result.newTier, InterruptTier.warningSpoken);
      });

      test('cutoff at 100%', () {
        final tracker = ParticipantTracker(
          participants: ['Alice'],
          perPersonDuration: const Duration(seconds: 60),
        );
        tracker.startCurrentParticipant(t);

        // Clear earlier tiers.
        tracker.check(t.add(const Duration(seconds: 45)));
        tracker.check(t.add(const Duration(seconds: 56)));

        // 60s = exactly 100%
        final result = tracker.check(t.add(const Duration(seconds: 60)));

        expect(result.newTier, InterruptTier.cutoff);
        expect(result.shouldAdvance, isTrue);
      });

      test('firmCutoff at 117%', () {
        final tracker = ParticipantTracker(
          participants: ['Alice'],
          perPersonDuration: const Duration(seconds: 60),
        );
        tracker.startCurrentParticipant(t);

        // Clear earlier tiers.
        tracker.check(t.add(const Duration(seconds: 45)));
        tracker.check(t.add(const Duration(seconds: 56)));
        tracker.check(t.add(const Duration(seconds: 60)));

        // 70.2s = 117% (use 71s > 117%)
        final result = tracker.check(t.add(const Duration(seconds: 71)));

        expect(result.newTier, InterruptTier.firmCutoff);
        expect(result.shouldAdvance, isTrue);
      });

      test('each tier is reported only once', () {
        final tracker = ParticipantTracker(
          participants: ['Alice'],
          perPersonDuration: const Duration(seconds: 60),
        );
        tracker.startCurrentParticipant(t);

        // First check at 75% — reports listenForPause.
        final first = tracker.check(t.add(const Duration(seconds: 46)));
        expect(first.newTier, InterruptTier.listenForPause);

        // Second check still at 75%+ — reports none (already reported).
        final second = tracker.check(t.add(const Duration(seconds: 47)));
        expect(second.newTier, InterruptTier.none);
      });

      test('advance resets tier for next participant', () {
        final tracker = ParticipantTracker(
          participants: ['Alice', 'Bob'],
          perPersonDuration: const Duration(seconds: 60),
        );
        tracker.startCurrentParticipant(t);

        // Trigger all tiers for Alice.
        tracker.check(t.add(const Duration(seconds: 45)));
        tracker.check(t.add(const Duration(seconds: 56)));
        tracker.check(t.add(const Duration(seconds: 60)));

        // Advance to Bob — starts fresh.
        tracker.advance(t.add(const Duration(seconds: 60)));

        // Bob should start at none, then reach listenForPause at his 75%.
        final result = tracker.check(t.add(const Duration(seconds: 105)));
        expect(result.newTier, InterruptTier.listenForPause);
        expect(result.participant, 'Bob');
      });

      test('thresholds scale with custom duration', () {
        // 120s per person — 75% = 90s, 92% = 110.4s, 100% = 120s
        final tracker = ParticipantTracker(
          participants: ['Alice'],
          perPersonDuration: const Duration(seconds: 120),
        );
        tracker.startCurrentParticipant(t);

        // 89s < 75% → none
        expect(
          tracker.check(t.add(const Duration(seconds: 89))).newTier,
          InterruptTier.none,
        );

        // 90s = 75% → listenForPause
        expect(
          tracker.check(t.add(const Duration(seconds: 90))).newTier,
          InterruptTier.listenForPause,
        );
      });
    });

    group('check returns correct participant', () {
      test('result includes current participant name', () {
        final tracker = ParticipantTracker(
          participants: ['Alice', 'Bob'],
          perPersonDuration: const Duration(seconds: 60),
        );
        tracker.startCurrentParticipant(t);

        final result = tracker.check(t.add(const Duration(seconds: 45)));
        expect(result.participant, 'Alice');
      });
    });
  });
}
