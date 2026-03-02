import 'package:imagineering_pm_bot/src/meetup/meet_browser.dart';
import 'package:imagineering_pm_bot/src/meetup/meetup_config.dart';
import 'package:imagineering_pm_bot/src/meetup/meetup_facilitator.dart';
import 'package:imagineering_pm_bot/src/meetup/meetup_session.dart';
import 'package:test/test.dart';

void main() {
  late FakeMeetBrowser browser;
  late MeetupConfig config;
  late MeetupFacilitator facilitator;

  setUp(() {
    browser = FakeMeetBrowser();
    config = const MeetupConfig(
      meetLink: 'https://meet.google.com/test-123',
      participants: ['Alice', 'Bob', 'Charlie'],
    );
    facilitator = MeetupFacilitator(browser: browser, config: config);
  });

  group('start', () {
    test('joins Meet, enables captions, and announces', () async {
      final now = DateTime(2026, 3, 28, 10, 0);
      await facilitator.start(now);

      expect(browser.calls[0], contains('joinMeet'));
      expect(browser.calls[1], 'enableCaptions()');
      expect(browser.spokenTexts, hasLength(1));
      expect(browser.spokenTexts[0], contains('Dreamfinder'));
      expect(facilitator.phase, MeetupPhase.intros);
      expect(facilitator.isRunning, isTrue);
    });

    test('throws if called twice', () async {
      final now = DateTime(2026, 3, 28, 10, 0);
      await facilitator.start(now);

      expect(() => facilitator.start(now), throwsStateError);
    });

    test('includes participant count in announcement', () async {
      final now = DateTime(2026, 3, 28, 10, 0);
      await facilitator.start(now);

      expect(browser.spokenTexts[0], contains('3 builders'));
    });

    test('uses generic announcement when no participants configured', () async {
      final noParticipants = MeetupFacilitator(
        browser: browser,
        config: const MeetupConfig(
          meetLink: 'https://meet.google.com/test',
        ),
      );

      await noParticipants.start(DateTime(2026, 3, 28, 10, 0));

      expect(browser.spokenTexts[0], isNot(contains('builders')));
      expect(browser.spokenTexts[0], contains('Dreamfinder'));
    });
  });

  group('tick', () {
    test('does nothing when not started', () async {
      await facilitator.tick(DateTime(2026, 3, 28, 10, 0));

      expect(browser.calls, isEmpty);
    });

    test('does nothing when phase has not expired', () async {
      final start = DateTime(2026, 3, 28, 10, 0);
      await facilitator.start(start);
      browser.spokenTexts.clear();

      // 2 minutes into 5-minute intros — not expired.
      await facilitator.tick(start.add(const Duration(minutes: 2)));

      expect(browser.spokenTexts, isEmpty);
    });

    test('advances phase when time expires', () async {
      final start = DateTime(2026, 3, 28, 10, 0);
      await facilitator.start(start);
      browser.spokenTexts.clear();

      // 5 minutes into intros — expired, should advance to sprint1.
      await facilitator.tick(start.add(const Duration(minutes: 5)));

      expect(facilitator.phase, MeetupPhase.sprint1);
      expect(browser.spokenTexts, hasLength(1));
      expect(browser.spokenTexts[0], contains('Sprint 1'));
    });

    test('sends 5-min warning during sprint', () async {
      final start = DateTime(2026, 3, 28, 10, 0);
      await facilitator.start(start);

      // Advance past intros → sprint1 (intros expire at t+5).
      await facilitator.tick(start.add(const Duration(minutes: 5)));
      browser.spokenTexts.clear();

      // Sprint1 started at t+5, lasts 25min.
      // At t+25min: sprint1 elapsed = 20min, 5min remaining.
      await facilitator.tick(start.add(const Duration(minutes: 25)));

      expect(
        browser.spokenTexts,
        contains('Five minutes left in this sprint!'),
      );
    });

    test('sends 1-min warning during sprint', () async {
      final start = DateTime(2026, 3, 28, 10, 0);
      await facilitator.start(start);

      // Advance to sprint1.
      await facilitator.tick(start.add(const Duration(minutes: 5)));

      // Trigger 5-min warning to clear it.
      await facilitator.tick(start.add(const Duration(minutes: 25)));
      browser.spokenTexts.clear();

      // Sprint1 started at t+5, so at t+29min: 1min remaining.
      await facilitator.tick(start.add(const Duration(minutes: 29)));

      expect(
        browser.spokenTexts,
        contains('One minute! Start wrapping up.'),
      );
    });

    test('does not repeat warnings within the same phase', () async {
      final start = DateTime(2026, 3, 28, 10, 0);
      await facilitator.start(start);
      await facilitator.tick(start.add(const Duration(minutes: 5)));
      browser.spokenTexts.clear();

      // First 5-min warning.
      await facilitator.tick(start.add(const Duration(minutes: 25)));
      expect(
        browser.spokenTexts.where((t) => t.contains('Five minutes')),
        hasLength(1),
      );

      // Another tick still in the 5-min window — no repeat.
      await facilitator.tick(start.add(const Duration(minutes: 26)));
      expect(
        browser.spokenTexts.where((t) => t.contains('Five minutes')),
        hasLength(1),
      );
    });

    test('warnings reset between sprints', () async {
      final start = DateTime(2026, 3, 28, 10, 0);
      await facilitator.start(start);

      // Phase timeline (cumulative from start):
      //  t+0:   intros     (5 min)
      //  t+5:   sprint1   (25 min)
      //  t+30:  break1    (10 min)
      //  t+40:  sprint2   (25 min)

      // Advance: intros → sprint1.
      await facilitator.tick(start.add(const Duration(minutes: 5)));

      // 5-min warning in sprint1.
      await facilitator.tick(start.add(const Duration(minutes: 25)));

      // Sprint1 expires → break1.
      await facilitator.tick(start.add(const Duration(minutes: 30)));

      // Break1 expires → sprint2.
      await facilitator.tick(start.add(const Duration(minutes: 40)));
      browser.spokenTexts.clear();

      // 5-min warning in sprint2 (started at t+40, 5min remaining at t+60).
      await facilitator.tick(start.add(const Duration(minutes: 60)));

      expect(
        browser.spokenTexts,
        contains('Five minutes left in this sprint!'),
      );
    });

    test('does not send sprint warnings during breaks', () async {
      final start = DateTime(2026, 3, 28, 10, 0);
      await facilitator.start(start);

      // Advance through intros → sprint1 → break1.
      await facilitator.tick(start.add(const Duration(minutes: 5)));
      await facilitator.tick(start.add(const Duration(minutes: 30)));
      browser.spokenTexts.clear();

      // Midway through break1 — no sprint warnings should fire.
      await facilitator.tick(start.add(const Duration(minutes: 35)));

      expect(
        browser.spokenTexts.where((t) => t.contains('minutes left')),
        isEmpty,
      );
    });

    test('announces each phase with config-aware durations', () async {
      final customConfig = MeetupFacilitator(
        browser: browser,
        config: const MeetupConfig(
          meetLink: 'https://meet.google.com/test',
          sprintDuration: Duration(minutes: 15),
          breakDuration: Duration(minutes: 5),
          introTotalDuration: Duration(minutes: 3),
        ),
      );

      final start = DateTime(2026, 3, 28, 10, 0);
      await customConfig.start(start);
      browser.spokenTexts.clear();

      // Advance: intros (3min) → sprint1.
      await customConfig.tick(start.add(const Duration(minutes: 3)));

      expect(browser.spokenTexts[0], contains('15 minutes'));
    });
  });

  group('stop', () {
    test('speaks goodbye and leaves', () async {
      final now = DateTime(2026, 3, 28, 10, 0);
      await facilitator.start(now);
      browser.spokenTexts.clear();

      await facilitator.stop(now);

      expect(browser.spokenTexts, hasLength(1));
      expect(browser.spokenTexts[0], contains('wrap'));
      expect(browser.isConnected, isFalse);
      expect(facilitator.isRunning, isFalse);
      expect(facilitator.phase, MeetupPhase.done);
    });

    test('does nothing when not started', () async {
      await facilitator.stop(DateTime(2026, 3, 28, 10, 0));

      expect(browser.calls, isEmpty);
    });

    test('does nothing when already done', () async {
      final start = DateTime(2026, 3, 28, 10, 0);
      await facilitator.start(start);

      // Run to completion.
      final transitions = [5, 30, 40, 65, 75, 100, 110, 115];
      for (final mins in transitions) {
        await facilitator.tick(start.add(Duration(minutes: mins)));
      }
      browser.spokenTexts.clear();
      browser.calls.clear();

      // Stop after already done — no-op.
      await facilitator.stop(start.add(const Duration(minutes: 120)));

      expect(browser.spokenTexts, isEmpty);
      expect(browser.calls, isEmpty);
    });
  });

  group('full session flow', () {
    test('runs from start to finish through all phases', () async {
      final t = DateTime(2026, 3, 28, 10, 0);
      await facilitator.start(t);

      // Phase timeline (cumulative minutes from start):
      //  t+0:   intros     (5 min)
      //  t+5:   sprint1   (25 min)
      //  t+30:  break1    (10 min)
      //  t+40:  sprint2   (25 min)
      //  t+65:  break2    (10 min)
      //  t+75:  sprint3   (25 min)
      //  t+100: break3    (10 min)
      //  t+110: demos      (5 min)
      //  t+115: done

      final transitions = <int>[5, 30, 40, 65, 75, 100, 110, 115];
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

      for (var i = 0; i < transitions.length; i++) {
        await facilitator.tick(t.add(Duration(minutes: transitions[i])));
        expect(
          facilitator.phase,
          expectedPhases[i],
          reason: 'At t+${transitions[i]}min expected ${expectedPhases[i]}',
        );
      }

      expect(facilitator.isRunning, isFalse);
      expect(browser.isConnected, isFalse);
    });

    test('speaks an announcement at every phase transition', () async {
      final t = DateTime(2026, 3, 28, 10, 0);
      await facilitator.start(t);

      // Intro announcement already spoken.
      expect(browser.spokenTexts, hasLength(1));

      final transitions = [5, 30, 40, 65, 75, 100, 110, 115];
      for (final mins in transitions) {
        await facilitator.tick(t.add(Duration(minutes: mins)));
      }

      // 1 intro + 8 phase transitions = 9 announcements total.
      // Plus sprint warnings: 3 sprints x 2 warnings = 6 warnings.
      // But warnings only fire if we tick at the right time.
      // In this test we jump directly to expiry times, so no warning
      // ticks happen (remaining = 0, guards prevent warning).
      // So we expect exactly 9 spoken texts.
      expect(browser.spokenTexts, hasLength(9));
    });

    test('total session duration matches expected ~2 hours', () async {
      // intros(5) + 3*(sprint(25) + break(10)) + demos(5) = 115 min
      const expected = Duration(minutes: 115);
      var total = Duration.zero;
      for (final phase in MeetupPhase.values) {
        total += facilitator.session.phaseDuration(phase);
      }
      expect(total, expected);
    });
  });
}
