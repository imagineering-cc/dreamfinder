import 'package:sqlite3/sqlite3.dart';

/// Current schema version. Bump this and add a migration block in
/// [_runMigrations] whenever the schema changes.
const schemaVersion = 5;

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
      CREATE TABLE IF NOT EXISTS signal_workspace_links (
        id                  INTEGER PRIMARY KEY AUTOINCREMENT,
        signal_group_id     TEXT    NOT NULL UNIQUE,
        workspace_public_id TEXT    NOT NULL,
        workspace_name      TEXT    NOT NULL,
        created_at          TEXT    NOT NULL DEFAULT (datetime('now')),
        created_by_uuid     TEXT    NOT NULL
      )
    ''');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS signal_user_links (
        id                         INTEGER PRIMARY KEY AUTOINCREMENT,
        signal_uuid                TEXT    NOT NULL UNIQUE,
        signal_display_name        TEXT,
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
        signal_group_id  TEXT    NOT NULL,
        reminder_type    TEXT    NOT NULL DEFAULT 'overdue',
        last_reminder_at TEXT    NOT NULL,
        UNIQUE(card_public_id, signal_group_id, reminder_type)
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
        signal_group_id TEXT    NOT NULL UNIQUE,
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
        signal_group_id TEXT    NOT NULL UNIQUE,
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
        signal_group_id    TEXT    NOT NULL,
        date               TEXT    NOT NULL,
        prompt_message_id  TEXT,
        summary_message_id TEXT,
        status             TEXT    NOT NULL DEFAULT 'active',
        nudged_at          INTEGER,
        UNIQUE(signal_group_id, date)
      )
    ''');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS standup_responses (
        id                  INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id          INTEGER NOT NULL REFERENCES standup_sessions(id),
        signal_uuid         TEXT    NOT NULL,
        signal_display_name TEXT,
        yesterday           TEXT,
        today               TEXT,
        blockers            TEXT,
        raw_message         TEXT,
        UNIQUE(session_id, signal_uuid)
      )
    ''');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS calendar_reminders (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        event_uid       TEXT    NOT NULL,
        signal_group_id TEXT    NOT NULL,
        reminder_window TEXT    NOT NULL,
        sent_at         TEXT    NOT NULL,
        UNIQUE(event_uid, signal_group_id, reminder_window)
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
        signal_group_id   TEXT    NOT NULL,
        date              TEXT    NOT NULL,
        status            TEXT    NOT NULL DEFAULT 'dreaming'
                          CHECK (status IN ('dreaming', 'completed', 'failed')),
        triggered_by_uuid TEXT    NOT NULL,
        started_at        TEXT    NOT NULL DEFAULT (datetime('now')),
        completed_at      TEXT,
        error_message     TEXT,
        UNIQUE(signal_group_id, date)
      )
    ''');
  }
}
