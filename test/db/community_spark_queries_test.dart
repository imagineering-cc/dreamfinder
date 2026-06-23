import 'package:dreamfinder/src/db/database.dart';
import 'package:dreamfinder/src/db/queries.dart';
import 'package:test/test.dart';

/// Tests for the Community Spark draft state machine (migration v10).
///
/// The lifecycle is `pending → published | dropped`. Safety-critical
/// properties under test: the single-pending invariant (partial unique
/// index), the publish CAS (only one transition wins — no cross-process
/// double-publish), staleness expiry, and the period guard.
void main() {
  late BotDatabase db;
  late Queries q;

  setUp(() {
    db = BotDatabase.inMemory();
    q = Queries(db);
  });

  tearDown(() => db.close());

  final now = DateTime.utc(2026, 6, 23, 2, 0);

  group('draft creation + retrieval', () {
    test('a created draft is retrievable as the pending draft', () {
      q.createSparkDraft(
        draftId: 'd1',
        text: 'spark one',
        now: now,
        hook: 'repo X',
      );
      final d = q.getPendingSparkDraft(now);
      expect(d, isNotNull);
      expect(d!.draftId, 'd1');
      expect(d.text, 'spark one');
      expect(d.hook, 'repo X');
      expect(d.status, SparkDraftStatus.pending);
    });

    test('no pending draft returns null', () {
      expect(q.getPendingSparkDraft(now), isNull);
    });
  });

  group('single-pending invariant', () {
    test('creating a second pending draft throws (partial unique index)', () {
      q.createSparkDraft(draftId: 'd1', text: 'one', now: now);
      expect(
        () => q.createSparkDraft(draftId: 'd2', text: 'two', now: now),
        throwsA(anything),
      );
    });

    test('the pending slot frees once the first draft is published', () {
      q.createSparkDraft(draftId: 'd1', text: 'one', now: now);
      expect(q.publishSparkDraft('d1', now), isTrue);
      // Slot is free — a new draft can be created.
      q.createSparkDraft(draftId: 'd2', text: 'two', now: now);
      expect(q.getPendingSparkDraft(now)!.draftId, 'd2');
    });

    test(
      'the pending slot frees once the first draft is dropped (expired)',
      () {
        final old = now.subtract(const Duration(hours: 48));
        q.createSparkDraft(draftId: 'd1', text: 'one', now: old);
        expect(q.expireStaleDrafts(now), 1);
        q.createSparkDraft(draftId: 'd2', text: 'two', now: now);
        expect(q.getPendingSparkDraft(now)!.draftId, 'd2');
      },
    );
  });

  group('publish CAS', () {
    test('publish transitions pending → published and returns true once', () {
      q.createSparkDraft(draftId: 'd1', text: 'one', now: now);
      expect(q.publishSparkDraft('d1', now), isTrue);
      // No pending draft remains.
      expect(q.getPendingSparkDraft(now), isNull);
    });

    test(
      'a repeat publish of the same draft returns false (idempotent CAS)',
      () {
        q.createSparkDraft(draftId: 'd1', text: 'one', now: now);
        expect(q.publishSparkDraft('d1', now), isTrue);
        // Second call — already published, CAS loses.
        expect(q.publishSparkDraft('d1', now), isFalse);
      },
    );

    test('publishing a non-existent draft returns false', () {
      expect(q.publishSparkDraft('nope', now), isFalse);
    });

    test('publishing stamps the period guard', () {
      q.createSparkDraft(draftId: 'd1', text: 'one', now: now);
      expect(q.lastPublishedSparkAt(), isNull);
      q.publishSparkDraft('d1', now);
      expect(q.lastPublishedSparkAt(), now);
    });
  });

  group('staleness', () {
    test('getPendingSparkDraft hides a draft older than staleAfter', () {
      final old = now.subtract(const Duration(hours: 25));
      q.createSparkDraft(draftId: 'd1', text: 'one', now: old);
      expect(q.getPendingSparkDraft(now), isNull); // >24h → hidden
      expect(
        q.getPendingSparkDraft(now, staleAfter: const Duration(hours: 48)),
        isNotNull,
      ); // within a wider window → visible
    });

    test('expireStaleDrafts only drops drafts past the window', () {
      final fresh = now.subtract(const Duration(hours: 1));
      q.createSparkDraft(draftId: 'fresh', text: 'fresh', now: fresh);
      expect(q.expireStaleDrafts(now), 0); // fresh one survives
      expect(q.getPendingSparkDraft(now)!.draftId, 'fresh');
    });
  });

  group('period guard CAS', () {
    test('first claim succeeds, a claim within minInterval fails', () {
      const week = Duration(days: 7);
      expect(q.claimSparkPeriod(now, minInterval: week), isTrue);
      final soon = now.add(const Duration(days: 2));
      expect(q.claimSparkPeriod(soon, minInterval: week), isFalse);
    });

    test('a claim after minInterval succeeds again', () {
      const week = Duration(days: 7);
      expect(q.claimSparkPeriod(now, minInterval: week), isTrue);
      final later = now.add(const Duration(days: 8));
      expect(q.claimSparkPeriod(later, minInterval: week), isTrue);
    });
  });

  group('anti-repetition window', () {
    test('recentPublishedSparks returns published texts newest-first', () {
      q.createSparkDraft(draftId: 'd1', text: 'first', now: now);
      q.publishSparkDraft('d1', now);
      final later = now.add(const Duration(days: 7));
      q.createSparkDraft(draftId: 'd2', text: 'second', now: later);
      q.publishSparkDraft('d2', later);

      final recent = q.recentPublishedSparks(limit: 4);
      expect(recent, ['second', 'first']);
    });

    test('a pending (unpublished) draft is not in the recent window', () {
      q.createSparkDraft(draftId: 'd1', text: 'pending one', now: now);
      expect(q.recentPublishedSparks(), isEmpty);
    });
  });
}
