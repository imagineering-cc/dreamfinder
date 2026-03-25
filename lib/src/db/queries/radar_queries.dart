/// Query mixin for the Repo Radar feature — tracked repos and contribution
/// drafts.
library;

import '../database.dart';
import '../schema.dart';

/// Mixin providing CRUD access to `tracked_repos` and `contribution_drafts`.
mixin RadarQueries {
  /// The database handle. Provided by the mixing-in class.
  BotDatabase get db;

  // ---------------------------------------------------------------------------
  // Tracked repos
  // ---------------------------------------------------------------------------

  /// Inserts or updates a tracked repo. Returns the row ID.
  ///
  /// If the repo already exists, updates the reason and source fields.
  int upsertTrackedRepo({
    required String repo,
    required String reason,
    required String sourceChatId,
    String? sourceMessage,
  }) {
    db.handle.execute(
      'INSERT INTO tracked_repos (repo, reason, source_chat_id, source_message) '
      'VALUES (?, ?, ?, ?) '
      'ON CONFLICT(repo) DO UPDATE SET '
      'reason = excluded.reason, '
      'source_chat_id = excluded.source_chat_id, '
      'source_message = excluded.source_message',
      [repo, reason, sourceChatId, sourceMessage],
    );
    return db.handle.lastInsertRowId;
  }

  /// Returns all tracked repos, ordered by most recently tracked.
  List<TrackedRepoRecord> getAllTrackedRepos() {
    final rows = db.handle.select(
      'SELECT * FROM tracked_repos ORDER BY tracked_at DESC',
    );
    return rows.map(_rowToTrackedRepo).toList();
  }

  /// Returns tracked repos for a specific chat.
  List<TrackedRepoRecord> getTrackedReposForChat(String chatId) {
    final rows = db.handle.select(
      'SELECT * FROM tracked_repos WHERE source_chat_id = ? '
      'ORDER BY tracked_at DESC',
      [chatId],
    );
    return rows.map(_rowToTrackedRepo).toList();
  }

  /// Returns a single tracked repo by `owner/name`, or `null` if not tracked.
  TrackedRepoRecord? getTrackedRepo(String repo) {
    final rows = db.handle.select(
      'SELECT * FROM tracked_repos WHERE repo = ?',
      [repo],
    );
    if (rows.isEmpty) return null;
    return _rowToTrackedRepo(rows.first);
  }

  /// Marks a repo as starred on GitHub.
  void markRepoStarred(String repo) {
    db.handle.execute(
      'UPDATE tracked_repos SET starred = 1 WHERE repo = ?',
      [repo],
    );
  }

  /// Updates the crawled metadata for a repo.
  void updateRepoMetadata(String repo, String metadataJson) {
    db.handle.execute(
      'UPDATE tracked_repos SET metadata = ?, '
      "last_crawled_at = datetime('now') WHERE repo = ?",
      [metadataJson, repo],
    );
  }

  /// Removes a repo from tracking.
  void deleteTrackedRepo(String repo) {
    db.handle.execute(
      'DELETE FROM tracked_repos WHERE repo = ?',
      [repo],
    );
  }

  TrackedRepoRecord _rowToTrackedRepo(Map<String, dynamic> row) {
    return TrackedRepoRecord(
      id: row['id'] as int,
      repo: row['repo'] as String,
      reason: row['reason'] as String,
      sourceChatId: row['source_chat_id'] as String,
      sourceMessage: row['source_message'] as String?,
      starred: (row['starred'] as int) == 1,
      metadata: row['metadata'] as String?,
      trackedAt: row['tracked_at'] as String,
      lastCrawledAt: row['last_crawled_at'] as String?,
    );
  }

  // ---------------------------------------------------------------------------
  // Contribution drafts
  // ---------------------------------------------------------------------------

  /// Creates a new contribution draft. Returns the row ID.
  int createContributionDraft({
    required String repo,
    required ContributionType type,
    required String title,
    required String body,
    String? targetBranch,
  }) {
    db.handle.execute(
      'INSERT INTO contribution_drafts '
      '(repo, type, title, body, target_branch) '
      'VALUES (?, ?, ?, ?, ?)',
      [repo, type.dbValue, title, body, targetBranch],
    );
    return db.handle.lastInsertRowId;
  }

  /// Returns all contribution drafts, optionally filtered by status.
  List<ContributionDraftRecord> getContributionDrafts({
    ContributionDraftStatus? status,
  }) {
    final where = status != null ? ' WHERE status = ?' : '';
    final params = status != null ? [status.dbValue] : <Object>[];
    final rows = db.handle.select(
      'SELECT * FROM contribution_drafts$where ORDER BY created_at DESC',
      params,
    );
    return rows.map(_rowToContributionDraft).toList();
  }

  /// Returns drafts for a specific repo.
  List<ContributionDraftRecord> getContributionDraftsForRepo(String repo) {
    final rows = db.handle.select(
      'SELECT * FROM contribution_drafts WHERE repo = ? '
      'ORDER BY created_at DESC',
      [repo],
    );
    return rows.map(_rowToContributionDraft).toList();
  }

  /// Returns a single draft by ID, or `null`.
  ContributionDraftRecord? getContributionDraft(int id) {
    final rows = db.handle.select(
      'SELECT * FROM contribution_drafts WHERE id = ?',
      [id],
    );
    if (rows.isEmpty) return null;
    return _rowToContributionDraft(rows.first);
  }

  /// Marks a draft as submitted with the resulting GitHub URL.
  void markDraftSubmitted(int id, String url) {
    db.handle.execute(
      'UPDATE contribution_drafts SET status = ?, '
      "submitted_at = datetime('now'), submitted_url = ? WHERE id = ?",
      ['submitted', url, id],
    );
  }

  /// Marks a draft as rejected.
  void markDraftRejected(int id) {
    db.handle.execute(
      'UPDATE contribution_drafts SET status = ? WHERE id = ?',
      ['rejected', id],
    );
  }

  ContributionDraftRecord _rowToContributionDraft(Map<String, dynamic> row) {
    return ContributionDraftRecord(
      id: row['id'] as int,
      repo: row['repo'] as String,
      type: ContributionType.fromDb(row['type'] as String),
      title: row['title'] as String,
      body: row['body'] as String,
      targetBranch: row['target_branch'] as String?,
      status: ContributionDraftStatus.fromDb(row['status'] as String),
      createdAt: row['created_at'] as String,
      submittedAt: row['submitted_at'] as String?,
      submittedUrl: row['submitted_url'] as String?,
    );
  }
}
