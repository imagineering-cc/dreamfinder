/// Queries for Community Spark — River's proactive community-ideation drafts.
///
/// The draft lifecycle is `pending → published | dropped`. The single-pending
/// invariant is enforced by a partial unique index (see migration v10), so a
/// human's approval in the private review room is unambiguous. State
/// transitions that gate an irreversible cross-platform publish use
/// compare-and-swap (check `updatedRows == 1`) so two processes can't both
/// publish the same draft.
library;

import '../database.dart';

/// Community Spark posting mode — a closed set. Parsed at the boundary so an
/// unknown value fails closed rather than silently behaving like `gated`.
enum CommunitySparkMode {
  /// Draft → human approval → publish. The only mode that publishes in PR1.
  gated,

  /// Autonomous publishing (PR2). Not implemented in PR1 — treated as `gated`
  /// (approval still required) with a startup warning, so it never posts to the
  /// public hub without a human.
  autonomous,

  /// Temporarily suspended — River drafts nothing.
  paused;

  /// Parses [raw] case-insensitively. Unknown/empty → null so the caller can
  /// choose the fail-closed default.
  static CommunitySparkMode? tryParse(String? raw) {
    switch (raw?.trim().toLowerCase()) {
      case 'gated':
        return CommunitySparkMode.gated;
      case 'autonomous':
        return CommunitySparkMode.autonomous;
      case 'paused':
        return CommunitySparkMode.paused;
      default:
        return null;
    }
  }
}

/// A spark draft's lifecycle status. Mirrors the DB CHECK constraint as a typed
/// closed set on the Dart side.
enum SparkDraftStatus {
  pending,
  published,
  dropped;

  /// Maps a DB status string to the enum. Throws on an unknown value (the DB
  /// CHECK constraint should make that impossible).
  static SparkDraftStatus fromDb(String raw) =>
      SparkDraftStatus.values.firstWhere((s) => s.name == raw);
}

/// A persisted community-spark draft and its lifecycle status.
class CommunitySparkDraft {
  const CommunitySparkDraft({
    required this.draftId,
    required this.text,
    required this.hook,
    required this.status,
    required this.composedAt,
  });

  final String draftId;
  final String text;
  final String? hook;
  final SparkDraftStatus status;
  final DateTime composedAt;
}

/// Mixin providing the Community Spark draft state machine.
mixin CommunitySparkQueries {
  /// The database handle. Provided by the mixing-in class.
  BotDatabase get db;

  /// `bot_metadata` key holding the ISO8601-UTC timestamp of the last
  /// **published** spark — the period/min-interval guard.
  static const periodKey = 'community_spark_last';

  /// Inserts a new `pending` draft.
  ///
  /// Throws if a pending draft already exists — the partial unique index is
  /// the real gate (the single-pending invariant). Callers should check
  /// [getPendingSparkDraft] first, but the DB enforces it regardless.
  ///
  /// [now] is stored as the composed-at timestamp (ISO8601 UTC) rather than
  /// the SQLite column default, so staleness math is timezone-unambiguous and
  /// tests can control the clock.
  void createSparkDraft({
    required String draftId,
    required String text,
    required DateTime now,
    String? hook,
    String? reviewEventId,
  }) {
    db.handle.execute(
      'INSERT INTO community_spark_drafts '
      '(draft_id, text, hook, review_event_id, composed_at) '
      'VALUES (?, ?, ?, ?, ?)',
      [draftId, text, hook, reviewEventId, now.toUtc().toIso8601String()],
    );
  }

  /// Returns the single pending draft if one exists and is not older than
  /// [staleAfter] relative to [now]; otherwise null. Read-only — use
  /// [expireStaleDrafts] to transition stale drafts to `dropped`.
  CommunitySparkDraft? getPendingSparkDraft(
    DateTime now, {
    Duration staleAfter = const Duration(hours: 24),
  }) {
    final rows = db.handle.select(
      'SELECT draft_id, text, hook, status, composed_at '
      "FROM community_spark_drafts WHERE status = 'pending' LIMIT 1",
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    final composedAt = DateTime.parse(r['composed_at'] as String);
    if (now.toUtc().difference(composedAt) > staleAfter) return null;
    return CommunitySparkDraft(
      draftId: r['draft_id'] as String,
      text: r['text'] as String,
      hook: r['hook'] as String?,
      status: SparkDraftStatus.fromDb(r['status'] as String),
      composedAt: composedAt,
    );
  }

  /// Transitions any pending draft older than [staleAfter] to `dropped`.
  /// Returns the number of drafts expired. An expired draft does NOT consume
  /// the publish period (the period guard is stamped on publish only).
  int expireStaleDrafts(
    DateTime now, {
    Duration staleAfter = const Duration(hours: 24),
  }) {
    final cutoff = now.toUtc().subtract(staleAfter).toIso8601String();
    db.handle.execute(
      "UPDATE community_spark_drafts SET status = 'dropped' "
      "WHERE status = 'pending' AND composed_at < ?",
      [cutoff],
    );
    return db.handle.updatedRows;
  }

  /// Atomically transitions draft [draftId] from `pending` to `published`.
  ///
  /// Returns true iff THIS call performed the transition — a concurrent or
  /// repeat call (cross-process double-publish) returns false. On success it
  /// also stamps the period guard, so the next spark respects the min-interval.
  /// This CAS is the publish gate: the irreversible hub post must only happen
  /// when this returns true.
  bool publishSparkDraft(
    String draftId,
    DateTime now, {
    String? publishedEventId,
  }) {
    final nowIso = now.toUtc().toIso8601String();
    // The CAS transition and the period-guard stamp commit in ONE transaction,
    // so a crash between them can't leave a draft `published` with the period
    // guard unset (which would let River re-draft immediately after restart).
    db.handle.execute('BEGIN IMMEDIATE');
    try {
      db.handle.execute(
        'UPDATE community_spark_drafts '
        "SET status = 'published', published_at = ?, published_event_id = ? "
        "WHERE draft_id = ? AND status = 'pending'",
        [nowIso, publishedEventId, draftId],
      );
      final won = db.handle.updatedRows == 1;
      if (won) {
        db.handle.execute(
          'INSERT INTO bot_metadata (key, value) VALUES (?, ?) '
          'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
          [periodKey, nowIso],
        );
      }
      db.handle.execute('COMMIT');
      return won;
    } on Object {
      db.handle.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Transitions a pending draft to `dropped` — e.g. when posting it to the
  /// review room failed, so it shouldn't block new drafts for the full stale
  /// window. No-op if the draft isn't pending.
  void dropSparkDraft(String draftId) {
    db.handle.execute(
      "UPDATE community_spark_drafts SET status = 'dropped' "
      "WHERE draft_id = ? AND status = 'pending'",
      [draftId],
    );
  }

  /// Stamps the publish-period guard to [now] (ISO8601 UTC).
  void setSparkPeriod(DateTime now) {
    db.handle.execute(
      'INSERT INTO bot_metadata (key, value) VALUES (?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      [periodKey, now.toUtc().toIso8601String()],
    );
  }

  /// The timestamp of the last published spark, or null if none.
  DateTime? lastPublishedSparkAt() {
    final rows = db.handle
        .select('SELECT value FROM bot_metadata WHERE key = ?', [periodKey]);
    if (rows.isEmpty) return null;
    return DateTime.tryParse(rows.first['value'] as String);
  }

  /// Atomically claims the spark period iff the last published spark is older
  /// than [minInterval] (or there was none). Returns true iff claimed.
  ///
  /// Used by the autonomous path, which has no draft row to CAS on. The
  /// insert-or-conditional-update is a single statement, so two processes
  /// cannot both claim — exactly one sees `updatedRows == 1`.
  bool claimSparkPeriod(DateTime now, {required Duration minInterval}) {
    final cutoff = now.toUtc().subtract(minInterval).toIso8601String();
    db.handle.execute(
      'INSERT INTO bot_metadata (key, value) VALUES (?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value '
      'WHERE bot_metadata.value < ?',
      [periodKey, now.toUtc().toIso8601String(), cutoff],
    );
    return db.handle.updatedRows == 1;
  }

  /// Texts of the most recently published sparks, newest first — fed into the
  /// compose prompt for anti-repetition.
  List<String> recentPublishedSparks({int limit = 4}) {
    final rows = db.handle.select(
      "SELECT text FROM community_spark_drafts WHERE status = 'published' "
      'ORDER BY published_at DESC LIMIT ?',
      [limit],
    );
    return [for (final r in rows) r['text'] as String];
  }

  /// Increments the human-engagement counter for a published spark (used by
  /// the engagement circuit-breaker).
  void recordSparkEngagement(String draftId, {int delta = 1}) {
    db.handle.execute(
      'UPDATE community_spark_drafts '
      'SET engagement_count = engagement_count + ? WHERE draft_id = ?',
      [delta, draftId],
    );
  }
}
