import 'dart:async';
import 'dart:math';

import 'package:dreamfinder/src/cron/scheduler.dart';
import 'package:dreamfinder/src/db/database.dart';
import 'package:dreamfinder/src/db/queries.dart';
import 'package:test/test.dart';

/// Tests for the Community Spark draft side (gated Phase 1).
///
/// River considers sparking at a jittered ~weekly cadence during Melbourne
/// waking hours; when there's a hook it posts a DRAFT to the private review
/// room (never the hub). Publishing is gated on human approval (tested
/// separately in the approval-handler tests).
///
/// Melbourne is UTC+10 in June (AEST, no DST). All test times are a Monday so
/// the Saturday event reminder never interferes, and before 03:00 UTC so the
/// daily-cleanup block doesn't run.
void main() {
  late BotDatabase db;
  late Queries queries;

  setUp(() {
    db = BotDatabase.inMemory();
    queries = Queries(db);
  });

  tearDown(() => db.close());

  const reviewRoom = '!review:imagineering.cc';
  const hubRoom = '!hub:imagineering.cc';

  // Monday 2026-06-22, 10:00 Melbourne == 00:00 UTC.
  final t0 = DateTime.utc(2026, 6, 22, 0, 0);
  // +2h == 12:00 Melbourne, still waking, still before 03:00 UTC.
  final t2h = t0.add(const Duration(hours: 2));

  Scheduler buildSpark(
    List<MapEntry<String, String>> sink, {
    String? review = reviewRoom,
    String? hub = hubRoom,
    Future<String> Function(String, String)? compose,
  }) =>
      Scheduler(
        queries: queries,
        sendMessage: (g, m) async => sink.add(MapEntry(g, m)),
        composeWithTools: compose ?? (g, t) async => 'Sparkly idea ✨',
        communitySparkReviewRoomId: review,
        communitySparkHubRoomId: hub,
        random: Random(42),
      );

  group('disabled / guards', () {
    test('does nothing when the review room is not configured', () async {
      final sent = <MapEntry<String, String>>[];
      final s = buildSpark(sent, review: null);
      await s.tick(t0);
      await s.tick(t2h);
      expect(sent, isEmpty);
      expect(queries.getPendingSparkDraft(t2h), isNull);
    });

    test('does nothing outside Melbourne waking hours', () async {
      final sent = <MapEntry<String, String>>[];
      // 22:00 UTC == 08:00 next-day Melbourne (before 09:00).
      final preDawn = DateTime.utc(2026, 6, 22, 22, 0);
      final s = buildSpark(sent);
      await s.tick(preDawn);
      await s.tick(preDawn.add(const Duration(minutes: 2)));
      expect(sent, isEmpty);
    });

    test('does nothing when composeWithTools is unavailable', () async {
      final sent = <MapEntry<String, String>>[];
      final s = Scheduler(
        queries: queries,
        sendMessage: (g, m) async => sent.add(MapEntry(g, m)),
        communitySparkReviewRoomId: reviewRoom,
        random: Random(42),
      );
      await s.tick(t0);
      await s.tick(t2h);
      expect(sent, isEmpty);
    });
  });

  group('drafting', () {
    test('first eligible tick staggers (no draft yet), then drafts', () async {
      final sent = <MapEntry<String, String>>[];
      final s = buildSpark(sent);

      await s.tick(t0); // initializes the jitter timer, no draft
      expect(sent, isEmpty);
      expect(queries.getPendingSparkDraft(t0), isNull);

      await s.tick(t2h); // past the stagger → draft
      expect(sent, hasLength(1));
      expect(sent.single.key, reviewRoom);
      expect(sent.single.value, contains('Draft community spark'));
      expect(sent.single.value, contains('Sparkly idea ✨'));
      expect(sent.single.value, contains('id `cs-'));

      // A pending draft now exists; nothing was posted to the hub.
      expect(queries.getPendingSparkDraft(t2h), isNotNull);
      expect(sent.where((e) => e.key == hubRoom), isEmpty);
    });

    test('skip-if-empty: a weak/absent hook posts nothing', () async {
      final sent = <MapEntry<String, String>>[];
      final s = buildSpark(sent, compose: (g, t) async => '   ');
      await s.tick(t0);
      await s.tick(t2h);
      expect(sent, isEmpty);
      expect(queries.getPendingSparkDraft(t2h), isNull);
    });

    test('strips wrapping quotes an LLM may add', () async {
      final sent = <MapEntry<String, String>>[];
      final s = buildSpark(sent, compose: (g, t) async => '"who wants in?"');
      await s.tick(t0);
      await s.tick(t2h);
      expect(sent.single.value, contains('who wants in?'));
      expect(sent.single.value, isNot(contains('"who wants in?"')));
    });

    test('injects recent published sparks into the compose prompt', () async {
      // Seed a published spark so anti-repetition has something to feed.
      queries.createSparkDraft(draftId: 'old', text: 'PAST SPARK', now: t0);
      queries.publishSparkDraft('old', t0);

      String? seenPrompt;
      final sent = <MapEntry<String, String>>[];
      final s = buildSpark(sent, compose: (g, t) async {
        seenPrompt = t;
        return 'fresh idea';
      });
      // Publish-gap is 5 days; advance past it so drafting is allowed.
      final later = t0.add(const Duration(days: 6));
      await s.tick(later);
      await s.tick(later.add(const Duration(hours: 2)));

      expect(seenPrompt, isNotNull);
      expect(seenPrompt, contains('PAST SPARK'));
    });
  });

  group('suppression + cadence guards', () {
    test('does not stack a second draft while one is pending', () async {
      queries.createSparkDraft(draftId: 'existing', text: 'pending one', now: t0);
      final sent = <MapEntry<String, String>>[];
      final s = buildSpark(sent);
      await s.tick(t0);
      await s.tick(t2h);
      expect(sent, isEmpty); // suppressed
      expect(queries.getPendingSparkDraft(t2h)!.draftId, 'existing');
    });

    test('does not draft within the publish-gap of the last published spark',
        () async {
      queries.setSparkPeriod(t0.subtract(const Duration(days: 2))); // 2d ago
      final sent = <MapEntry<String, String>>[];
      final s = buildSpark(sent);
      await s.tick(t0);
      await s.tick(t2h);
      expect(sent, isEmpty); // within 5-day gap
    });

    test('overlapping ticks do not produce two drafts', () async {
      final sent = <MapEntry<String, String>>[];
      final gate = Completer<String>();
      final s = buildSpark(sent, compose: (g, t) => gate.future);

      await s.tick(t0); // stagger
      final first = s.tick(t2h); // enters, awaits the slow compose
      await s.tick(t2h.add(const Duration(seconds: 1))); // overlaps → bails

      gate.complete('released spark');
      await first;

      expect(sent, hasLength(1));
    });
  });
}
