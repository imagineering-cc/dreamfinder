import 'package:sqlite3/sqlite3.dart';

/// Current schema version. Bump this and add a migration block in
/// [_runMigrations] whenever the schema changes.
const schemaVersion = 9;

/// SQLite database wrapper for Dreamfinder.
///
/// Manages the connection, schema versioning, and migrations. Use
/// [BotDatabase.open] for file-based persistence or [BotDatabase.inMemory]
/// for tests.
///
/// Schema changes are tracked via a `schema_version` table. Each version
/// maps to a migration block in [_runMigrations]. The `CREATE TABLE IF NOT
/// EXISTS` guards mean re-running a migration on an existing DB is safe.
class BotDatabase {
  BotDatabase._(this._db) {
    _initSchema();
  }

  /// Opens a file-backed SQLite database at [path], creating it if needed.
  factory BotDatabase.open(String path) {
    final db = sqlite3.open(path);
    return BotDatabase._(db);
  }

  /// Opens an in-memory database — ideal for tests.
  factory BotDatabase.inMemory() {
    final db = sqlite3.openInMemory();
    return BotDatabase._(db);
  }

  final Database _db;

  /// The underlying sqlite3 [Database] handle for direct queries.
  Database get handle => _db;

  /// Returns all user-created table names in the database.
  List<String> tableNames() {
    final result = _db.select(
      "SELECT name FROM sqlite_master WHERE type = 'table' "
      "AND name NOT LIKE 'sqlite_%'",
    );
    return [for (final row in result) row['name'] as String];
  }

  /// Returns all index names in the database.
  List<String> indexNames() {
    final result = _db.select(
      "SELECT name FROM sqlite_master WHERE type = 'index' "
      "AND name NOT LIKE 'sqlite_%'",
    );
    return [for (final row in result) row['name'] as String];
  }

  /// Closes the database connection.
  void close() {
    _db.dispose();
  }

  /// Returns the current schema version stored in the database, or 0 if the
  /// version table doesn't exist yet.
  int get currentSchemaVersion {
    try {
      final rows = _db.select('SELECT version FROM schema_version');
      return rows.isEmpty ? 0 : rows.first['version'] as int;
    } on SqliteException {
      return 0;
    }
  }

  void _initSchema() {
    // Enable FK enforcement — without this, REFERENCES clauses are decorative.
    _db.execute('PRAGMA foreign_keys = ON');

    // Create the version tracking table.
    _db.execute('''
      CREATE TABLE IF NOT EXISTS schema_version (
        version INTEGER NOT NULL
      )
    ''');

    final current = currentSchemaVersion;
    _runMigrations(current);
  }

  void _runMigrations(int fromVersion) {
    if (fromVersion < 1) _migrateToV1();
    if (fromVersion < 2) _migrateToV2();
    if (fromVersion < 3) _migrateToV3();
    if (fromVersion < 4) _migrateToV4();
    if (fromVersion < 5) _migrateToV5();
    if (fromVersion < 6) _migrateToV6();
    if (fromVersion < 7) _migrateToV7();
    if (fromVersion < 8) _migrateToV8();
    if (fromVersion < 9) _migrateToV9();

    _setVersion(schemaVersion);
  }

  void _setVersion(int version) {
    _db.execute('DELETE FROM schema_version');
    _db.execute(
      'INSERT INTO schema_version (version) VALUES (?)',
      [version],
    );
  }

  /// Version 1: initial schema with all domain tables.
  void _migrateToV1() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS conversations (
        chat_id    TEXT PRIMARY KEY,
        created_at TEXT NOT NULL DEFAULT (datetime('now')),
        last_activity TEXT NOT NULL DEFAULT (datetime('now'))
      )
    ''');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS messages (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        chat_id     TEXT    NOT NULL REFERENCES conversations(chat_id),
        role        TEXT    NOT NULL CHECK (role IN ('user', 'assistant')),
        content     TEXT    NOT NULL,
        sender_uuid TEXT,
        sender_name TEXT,
        created_at  TEXT    NOT NULL DEFAULT (datetime('now'))
      )
    ''');

    _db.execute('''
      CREATE INDEX IF NOT EXISTS idx_messages_chat_id
      ON messages(chat_id)
    ''');

    _db.execute('''
      CREATE INDEX IF NOT EXISTS idx_messages_created_at
      ON messages(created_at)
    ''');

    // --- Domain tables ---

    _db.execute('''
      CREATE TABLE IF NOT EXISTS workspace_links (
        id                  INTEGER PRIMARY KEY AUTOINCREMENT,
        group_id            TEXT    NOT NULL UNIQUE,
        workspace_public_id TEXT    NOT NULL,
        workspace_name      TEXT    NOT NULL,
        created_at          TEXT    NOT NULL DEFAULT (datetime('now')),
        created_by_uuid     TEXT    NOT NULL
      )
    ''');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS user_links (
        id                         INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id                    TEXT    NOT NULL UNIQUE,
        display_name               TEXT,
        kan_user_email             TEXT    NOT NULL,
        workspace_member_public_id TEXT,
        created_at                 TEXT    NOT NULL DEFAULT (datetime('now')),
        created_by_uuid            TEXT
      )
    ''');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS sent_reminders (
        id               INTEGER PRIMARY KEY AUTOINCREMENT,
        card_public_id   TEXT    NOT NULL,
        group_id         TEXT    NOT NULL,
        reminder_type    TEXT    NOT NULL DEFAULT 'overdue',
        last_reminder_at TEXT    NOT NULL,
        UNIQUE(card_public_id, group_id, reminder_type)
      )
    ''');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS bot_identity (
        id                 INTEGER PRIMARY KEY AUTOINCREMENT,
        name               TEXT    NOT NULL,
        pronouns           TEXT    NOT NULL,
        tone               TEXT    NOT NULL,
        tone_description   TEXT,
        chosen_at          TEXT    NOT NULL DEFAULT (datetime('now')),
        chosen_in_group_id TEXT
      )
    ''');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS default_board_config (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        group_id        TEXT    NOT NULL UNIQUE,
        board_public_id TEXT    NOT NULL,
        list_public_id  TEXT    NOT NULL,
        board_name      TEXT    NOT NULL,
        list_name       TEXT    NOT NULL,
        updated_at      TEXT    NOT NULL DEFAULT (datetime('now'))
      )
    ''');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS oauth_tokens (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        token_type  TEXT    NOT NULL UNIQUE,
        token_value TEXT    NOT NULL,
        expires_at  INTEGER,
        updated_at  TEXT    NOT NULL
      )
    ''');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS standup_config (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        group_id        TEXT    NOT NULL UNIQUE,
        enabled         INTEGER NOT NULL DEFAULT 1,
        prompt_hour     INTEGER NOT NULL DEFAULT 9,
        summary_hour    INTEGER NOT NULL DEFAULT 17,
        timezone        TEXT    NOT NULL DEFAULT 'Australia/Sydney',
        skip_break_days INTEGER NOT NULL DEFAULT 1,
        skip_weekends   INTEGER NOT NULL DEFAULT 1,
        nudge_hour      INTEGER
      )
    ''');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS standup_sessions (
        id                 INTEGER PRIMARY KEY AUTOINCREMENT,
        group_id           TEXT    NOT NULL,
        date               TEXT    NOT NULL,
        prompt_message_id  TEXT,
        summary_message_id TEXT,
        status             TEXT    NOT NULL DEFAULT 'active',
        nudged_at          INTEGER,
        UNIQUE(group_id, date)
      )
    ''');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS standup_responses (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id   INTEGER NOT NULL REFERENCES standup_sessions(id),
        user_id      TEXT    NOT NULL,
        display_name TEXT,
        yesterday    TEXT,
        today        TEXT,
        blockers     TEXT,
        raw_message  TEXT,
        UNIQUE(session_id, user_id)
      )
    ''');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS calendar_reminders (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        event_uid       TEXT    NOT NULL,
        group_id        TEXT    NOT NULL,
        reminder_window TEXT    NOT NULL,
        sent_at         TEXT    NOT NULL,
        UNIQUE(event_uid, group_id, reminder_window)
      )
    ''');
  }

  /// Version 2: composite index for efficient window trimming in
  /// [MessageRepository.trimToWindow].
  void _migrateToV2() {
    _db.execute('''
      CREATE INDEX IF NOT EXISTS idx_messages_chat_id_id
      ON messages(chat_id, id DESC)
    ''');
  }

  /// Version 3: general-purpose key-value store for bot metadata
  /// (deploy version tracking, feature flags, etc.).
  void _migrateToV3() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS bot_metadata (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
  }

  /// Version 4: RAG memory system — embedding storage, summaries, and
  /// consolidation tracking for semantic long-term memory.
  void _migrateToV4() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS memory_embeddings (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        message_id  INTEGER,
        chat_id     TEXT    NOT NULL,
        source_type TEXT    NOT NULL CHECK (source_type IN ('message', 'summary')),
        source_text TEXT    NOT NULL,
        sender_uuid TEXT,
        sender_name TEXT,
        visibility  TEXT    NOT NULL DEFAULT 'same_chat'
                    CHECK (visibility IN ('same_chat', 'cross_chat', 'private')),
        embedding   BLOB,
        created_at  TEXT    NOT NULL DEFAULT (datetime('now'))
      )
    ''');

    _db.execute('''
      CREATE INDEX IF NOT EXISTS idx_memory_chat
      ON memory_embeddings(chat_id)
    ''');

    _db.execute('''
      CREATE INDEX IF NOT EXISTS idx_memory_type
      ON memory_embeddings(source_type)
    ''');

    _db.execute('''
      CREATE INDEX IF NOT EXISTS idx_memory_vis
      ON memory_embeddings(visibility)
    ''');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS memory_summaries (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        chat_id         TEXT    NOT NULL,
        summary_text    TEXT    NOT NULL,
        message_id_from INTEGER NOT NULL,
        message_id_to   INTEGER NOT NULL,
        message_count   INTEGER NOT NULL,
        created_at      TEXT    NOT NULL DEFAULT (datetime('now'))
      )
    ''');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS memory_consolidation_state (
        chat_id              TEXT PRIMARY KEY,
        last_consolidated_id INTEGER NOT NULL DEFAULT 0,
        last_consolidated_at TEXT
      )
    ''');
  }

  /// Version 5: dream cycle tracking — autonomous nightly knowledge
  /// organization sessions.
  void _migrateToV5() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS dream_cycles (
        id                INTEGER PRIMARY KEY AUTOINCREMENT,
        group_id          TEXT    NOT NULL,
        date              TEXT    NOT NULL,
        status            TEXT    NOT NULL DEFAULT 'dreaming'
                          CHECK (status IN ('dreaming', 'completed', 'failed')),
        triggered_by_uuid TEXT    NOT NULL,
        started_at        TEXT    NOT NULL DEFAULT (datetime('now')),
        completed_at      TEXT,
        error_message     TEXT,
        UNIQUE(group_id, date)
      )
    ''');
  }

  /// Version 6: platform-agnostic rename — removes "signal" prefix from table
  /// and column names to support Matrix and future platforms.
  ///
  /// Uses `ALTER TABLE RENAME TO` and `ALTER TABLE RENAME COLUMN` (SQLite 3.25+,
  /// metadata-only operations — no data is rewritten).
  ///
  /// On fresh databases, V1 already creates tables with new names, so we skip
  /// the renames if the old tables don't exist.
  void _migrateToV6() {
    // Check if old tables exist — skip renames on fresh databases.
    final oldTables = _db
        .select(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "AND name IN ('signal_workspace_links', 'signal_user_links')",
        )
        .map((r) => r['name'] as String)
        .toSet();
    if (oldTables.isEmpty) return;

    // Table renames.
    _db.execute(
      'ALTER TABLE signal_workspace_links RENAME TO workspace_links',
    );
    _db.execute(
      'ALTER TABLE signal_user_links RENAME TO user_links',
    );

    // Column renames: workspace_links.
    _db.execute(
      'ALTER TABLE workspace_links RENAME COLUMN signal_group_id TO group_id',
    );

    // Column renames: user_links.
    _db.execute(
      'ALTER TABLE user_links RENAME COLUMN signal_uuid TO user_id',
    );
    _db.execute(
      'ALTER TABLE user_links RENAME COLUMN signal_display_name TO display_name',
    );

    // Column renames: sent_reminders.
    _db.execute(
      'ALTER TABLE sent_reminders RENAME COLUMN signal_group_id TO group_id',
    );

    // Column renames: default_board_config.
    _db.execute(
      'ALTER TABLE default_board_config '
      'RENAME COLUMN signal_group_id TO group_id',
    );

    // Column renames: standup_config.
    _db.execute(
      'ALTER TABLE standup_config RENAME COLUMN signal_group_id TO group_id',
    );

    // Column renames: standup_sessions.
    _db.execute(
      'ALTER TABLE standup_sessions RENAME COLUMN signal_group_id TO group_id',
    );

    // Column renames: standup_responses.
    _db.execute(
      'ALTER TABLE standup_responses RENAME COLUMN signal_uuid TO user_id',
    );
    _db.execute(
      'ALTER TABLE standup_responses '
      'RENAME COLUMN signal_display_name TO display_name',
    );

    // Column renames: calendar_reminders.
    _db.execute(
      'ALTER TABLE calendar_reminders '
      'RENAME COLUMN signal_group_id TO group_id',
    );

    // Column renames: dream_cycles.
    _db.execute(
      'ALTER TABLE dream_cycles RENAME COLUMN signal_group_id TO group_id',
    );
  }

  /// Version 7: Repo Radar — tracked repositories and contribution drafts
  /// for discovering interesting repos from conversation and preparing
  /// draft PRs/issues for human review.
  void _migrateToV7() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS tracked_repos (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        repo            TEXT    NOT NULL UNIQUE,
        reason          TEXT    NOT NULL,
        source_chat_id  TEXT    NOT NULL,
        source_message  TEXT,
        starred         INTEGER NOT NULL DEFAULT 0,
        metadata        TEXT,
        tracked_at      TEXT    NOT NULL DEFAULT (datetime('now')),
        last_crawled_at TEXT
      )
    ''');

    _db.execute('''
      CREATE INDEX IF NOT EXISTS idx_tracked_repos_chat
      ON tracked_repos(source_chat_id)
    ''');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS contribution_drafts (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        repo            TEXT    NOT NULL,
        type            TEXT    NOT NULL CHECK (type IN ('pr', 'issue')),
        title           TEXT    NOT NULL,
        body            TEXT    NOT NULL,
        target_branch   TEXT,
        status          TEXT    NOT NULL DEFAULT 'draft'
                        CHECK (status IN ('draft', 'submitted', 'rejected')),
        created_at      TEXT    NOT NULL DEFAULT (datetime('now')),
        submitted_at    TEXT,
        submitted_url   TEXT
      )
    ''');

    _db.execute('''
      CREATE INDEX IF NOT EXISTS idx_contribution_drafts_repo
      ON contribution_drafts(repo)
    ''');

    _db.execute('''
      CREATE INDEX IF NOT EXISTS idx_contribution_drafts_status
      ON contribution_drafts(status)
    ''');
  }

  /// Version 8: Task Radar — adds `radar_hour` to `standup_config` for
  /// scheduled proactive scans that synthesize across Kan, Outline, calendar,
  /// memory, and standups to suggest tasks the team should consider.
  void _migrateToV8() {
    _db.execute(
      'ALTER TABLE standup_config ADD COLUMN radar_hour INTEGER',
    );
  }

  /// Version 9: Personality traits — TARS-style proportional personality
  /// blending for the naming ceremony. Each trait is a 0–100 value tied
  /// to a bot_identity record.
  void _migrateToV9() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS personality_traits (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        identity_id INTEGER NOT NULL REFERENCES bot_identity(id),
        trait_name  TEXT    NOT NULL,
        trait_value INTEGER NOT NULL CHECK (trait_value BETWEEN 0 AND 100),
        UNIQUE(identity_id, trait_name)
      )
    ''');
  }
}
