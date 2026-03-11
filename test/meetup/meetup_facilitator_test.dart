import 'package:dreamfinder/src/meetup/meet_browser.dart';
import 'package:dreamfinder/src/meetup/meetup_config.dart';
import 'package:dreamfinder/src/meetup/meetup_facilitator.dart';
import 'package:dreamfinder/src/meetup/meetup_session.dart';
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
      expect(browser.calls[2], 'startCaptionScraping()');
      // Intro announcement + first participant prompt.
      expect(browser.spokenTexts, hasLength(2));
      expect(browser.spokenTexts[0], contains('Dreamfinder'));
      expect(browser.spokenTexts[1], contains('Alice'));
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

      // 30s into intros — Alice's 60s intro is at 50%, no tier fires.
      await facilitator.tick(start.add(const Duration(seconds: 30)));

      expect(browser.spokenTexts, isEmpty);
    });

    test('advances phase when time expires', () async {
      final start = DateTime(2026, 3, 28, 10, 0);
      await facilitator.start(start);
      browser.spokenTexts.clear();

      // 5 minutes into intros — expired, should advance to sprint1.
      // Participant tracker also fires (cutoff/firmCutoff for intro
      // participants who ran past their slot) before the phase transition.
      await facilitator.tick(start.add(const Duration(minutes: 5)));

      expect(facilitator.phase, MeetupPhase.sprint1);
      expect(
        browser.spokenTexts,
        contains(predicate<String>((s) => s.contains('Sprint 1'))),
      );
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

  group('participant tracking (intros)', () {
    test('start calls startCaptionScraping', () async {
      final now = DateTime(2026, 4, 25, 10, 0);
      await facilitator.start(now);

      expect(browser.captionScrapingStarted, isTrue);
      expect(browser.calls, contains('startCaptionScraping()'));
    });

    test('start prompts first participant for intro', () async {
      final now = DateTime(2026, 4, 25, 10, 0);
      await facilitator.start(now);

      // Should speak intro announcement + first participant prompt.
      expect(browser.spokenTexts, hasLength(2));
      expect(browser.spokenTexts[1], contains('Alice'));
      expect(browser.spokenTexts[1], contains('building'));
    });

    test('no participant prompt when participants list is empty', () async {
      final noParticipants = MeetupFacilitator(
        browser: browser,
        config: const MeetupConfig(
          meetLink: 'https://meet.google.com/test',
        ),
      );

      await noParticipants.start(DateTime(2026, 4, 25, 10, 0));

      // Only the generic intro announcement — no participant prompt.
      expect(browser.spokenTexts, hasLength(1));
    });

    test('speaks computed time warning for participant', () async {
      final t = DateTime(2026, 4, 25, 10, 0);
      final shortConfig = MeetupFacilitator(
        browser: browser,
        config: const MeetupConfig(
          meetLink: 'https://meet.google.com/test',
          participants: ['Alice', 'Bob'],
          introDuration: Duration(seconds: 60),
          introTotalDuration: Duration(minutes: 5),
        ),
      );

      await shortConfig.start(t);
      browser.spokenTexts.clear();

      // Alice's 60s intro, 92% = 55.2s → tick at 56s → 4s remaining.
      await shortConfig.tick(t.add(const Duration(seconds: 56)));

      expect(
        browser.spokenTexts,
        contains('4 seconds!'),
      );
    });

    test('cutoff thanks current and prompts next participant', () async {
      final t = DateTime(2026, 4, 25, 10, 0);
      await facilitator.start(t);
      browser.spokenTexts.clear();

      // Trigger listenForPause (75% of 60s = 45s).
      await facilitator.tick(t.add(const Duration(seconds: 45)));
      // Trigger warningSpoken (92% of 60s = 55.2s).
      await facilitator.tick(t.add(const Duration(seconds: 56)));
      browser.spokenTexts.clear();

      // Trigger cutoff (100% of 60s = 60s).
      await facilitator.tick(t.add(const Duration(seconds: 60)));

      // Should thank Alice and prompt Bob.
      expect(
        browser.spokenTexts,
        contains(predicate<String>((s) => s.contains('Alice'))),
      );
      expect(
        browser.spokenTexts,
        contains(predicate<String>((s) => s.contains('Bob'))),
      );
    });

    test('firm cutoff advances even if cutoff was skipped', () async {
      final t = DateTime(2026, 4, 25, 10, 0);
      await facilitator.start(t);
      browser.spokenTexts.clear();

      // Jump straight to firm cutoff (117% of 60s = 70.2s) skipping
      // intermediate ticks. Tiers accumulate in a single check.
      await facilitator.tick(t.add(const Duration(seconds: 71)));

      // Should still advance — firm cutoff message spoken.
      expect(
        browser.spokenTexts.any((s) => s.contains('Bob')),
        isTrue,
        reason: 'Should prompt next participant after firm cutoff',
      );
    });

    test('last participant gets "everyone" message instead of next prompt',
        () async {
      final t = DateTime(2026, 4, 25, 10, 0);
      final singleConfig = MeetupFacilitator(
        browser: browser,
        config: const MeetupConfig(
          meetLink: 'https://meet.google.com/test',
          participants: ['Alice'],
        ),
      );

      await singleConfig.start(t);
      browser.spokenTexts.clear();

      // Trigger through all tiers to cutoff.
      await singleConfig.tick(t.add(const Duration(seconds: 45)));
      await singleConfig.tick(t.add(const Duration(seconds: 56)));
      await singleConfig.tick(t.add(const Duration(seconds: 60)));

      expect(
        browser.spokenTexts.any((s) => s.contains('everyone')),
        isTrue,
        reason: 'Should say "everyone" when last participant finishes',
      );
    });
  });

  group('participant tracking (demos)', () {
    test('creates demo tracker and prompts first participant on demo phase',
        () async {
      final t = DateTime(2026, 4, 25, 10, 0);
      await facilitator.start(t);

      // Fast-forward through all phases to demos (t+110min).
      final transitions = [5, 30, 40, 65, 75, 100, 110];
      for (final mins in transitions) {
        await facilitator.tick(t.add(Duration(minutes: mins)));
      }

      // The transition to demos should speak the demos announcement
      // AND the first participant prompt.
      final demosTexts = browser.spokenTexts.where(
        (s) => s.contains('Demo time') || s.contains('Alice'),
      );
      expect(demosTexts.length, greaterThanOrEqualTo(2));
    });

    test('demo participant gets computed time warning', () async {
      final t = DateTime(2026, 4, 25, 10, 0);
      await facilitator.start(t);

      // Fast-forward to demos phase.
      final transitions = [5, 30, 40, 65, 75, 100, 110];
      for (final mins in transitions) {
        await facilitator.tick(t.add(Duration(minutes: mins)));
      }
      browser.spokenTexts.clear();

      // Demos started at t+110. Alice has 60s demo.
      // 92% of 60s = 55.2s → tick at t+110min + 56s → 4s remaining.
      final demosStart = t.add(const Duration(minutes: 110));
      await facilitator.tick(demosStart.add(const Duration(seconds: 56)));

      expect(browser.spokenTexts, contains('4 seconds!'));
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

      // Intro announcement + first participant prompt.
      expect(browser.spokenTexts, hasLength(2));

      final transitions = [5, 30, 40, 65, 75, 100, 110, 115];
      for (final mins in transitions) {
        await facilitator.tick(t.add(Duration(minutes: mins)));
      }

      // Verify all phase transition announcements are present.
      final phaseAnnouncements = browser.spokenTexts.where(
        (s) =>
            s.contains('Sprint') ||
            s.contains('break') ||
            s.contains('Demo time') ||
            s.contains('wrap') ||
            s.contains('Dreamfinder'),
      );
      // intro + sprint1 + break1 + sprint2 + break2 + sprint3 + break3
      // + demos + done = 9 phase announcements.
      expect(phaseAnnouncements.length, greaterThanOrEqualTo(9));
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
