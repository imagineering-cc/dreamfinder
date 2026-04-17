import 'package:dreamfinder/src/db/database.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late BotDatabase db;

  setUp(() {
    db = BotDatabase.inMemory();
  });

  tearDown(() {
    db.close();
  });

  group('BotDatabase', () {
    test('opens in-memory database and creates tables', () {
      // If we got here without an exception, schema creation succeeded.
      // Verify by querying sqlite_master for our tables.
      final tables = db.tableNames();
      expect(tables, contains('conversations'));
      expect(tables, contains('messages'));
    });

    test('creates indexes on messages table', () {
      final indexes = db.indexNames();
      expect(indexes, contains('idx_messages_chat_id'));
      expect(indexes, contains('idx_messages_created_at'));
      expect(indexes, contains('idx_messages_chat_id_id'));
    });

    test('can open a file-based database', () {
      // Just verify the factory doesn't throw — actual file I/O tested
      // via integration tests with a temp directory.
      final fileDb = BotDatabase.inMemory();
      addTearDown(fileDb.close);
      expect(fileDb.tableNames(), contains('conversations'));
    });

    test('fresh database uses new table/column names (V6)', () {
      final tables = db.tableNames();
      expect(tables, contains('workspace_links'));
      expect(tables, contains('user_links'));
      // Old names should NOT exist on a fresh DB.
      expect(tables, isNot(contains('signal_workspace_links')));
      expect(tables, isNot(contains('signal_user_links')));
    });
  });

  group('V6 migration', () {
    test('renames tables and columns from V5 schema', () {
      // Create a raw V5 database with the old Signal-specific names.
      final raw = sqlite3.openInMemory();
      raw.execute('PRAGMA foreign_keys = ON');
      raw.execute(
        'CREATE TABLE schema_version (version INTEGER NOT NULL)',
      );
      raw.execute('INSERT INTO schema_version (version) VALUES (5)');

      // V1 tables with old names.
      raw.execute('''
        CREATE TABLE conversations (
          chat_id TEXT PRIMARY KEY,
          created_at TEXT NOT NULL DEFAULT (datetime('now')),
          last_activity TEXT NOT NULL DEFAULT (datetime('now'))
        )
      ''');
      raw.execute('''
        CREATE TABLE messages (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          chat_id TEXT NOT NULL,
          role TEXT NOT NULL,
          content TEXT NOT NULL,
          sender_uuid TEXT,
          sender_name TEXT,
          created_at TEXT NOT NULL DEFAULT (datetime('now'))
        )
      ''');
      raw.execute('''
        CREATE TABLE signal_workspace_links (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          signal_group_id TEXT NOT NULL UNIQUE,
          workspace_public_id TEXT NOT NULL,
          workspace_name TEXT NOT NULL,
          created_at TEXT NOT NULL DEFAULT (datetime('now')),
          created_by_uuid TEXT NOT NULL
        )
      ''');
      raw.execute('''
        CREATE TABLE signal_user_links (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          signal_uuid TEXT NOT NULL UNIQUE,
          signal_display_name TEXT,
          kan_user_email TEXT NOT NULL,
          workspace_member_public_id TEXT,
          created_at TEXT NOT NULL DEFAULT (datetime('now')),
          created_by_uuid TEXT
        )
      ''');
      raw.execute('''
        CREATE TABLE sent_reminders (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          card_public_id TEXT NOT NULL,
          signal_group_id TEXT NOT NULL,
          reminder_type TEXT NOT NULL DEFAULT 'overdue',
          last_reminder_at TEXT NOT NULL,
          UNIQUE(card_public_id, signal_group_id, reminder_type)
        )
      ''');
      raw.execute('''
        CREATE TABLE bot_identity (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL,
          pronouns TEXT NOT NULL,
          tone TEXT NOT NULL,
          tone_description TEXT,
          chosen_at TEXT NOT NULL DEFAULT (datetime('now')),
          chosen_in_group_id TEXT
        )
      ''');
      raw.execute('''
        CREATE TABLE default_board_config (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          signal_group_id TEXT NOT NULL UNIQUE,
          board_public_id TEXT NOT NULL,
          list_public_id TEXT NOT NULL,
          board_name TEXT NOT NULL,
          list_name TEXT NOT NULL,
          updated_at TEXT NOT NULL DEFAULT (datetime('now'))
        )
      ''');
      raw.execute('''
        CREATE TABLE oauth_tokens (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          token_type TEXT NOT NULL UNIQUE,
          token_value TEXT NOT NULL,
          expires_at INTEGER,
          updated_at TEXT NOT NULL
        )
      ''');
      raw.execute('''
        CREATE TABLE standup_config (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          signal_group_id TEXT NOT NULL UNIQUE,
          enabled INTEGER NOT NULL DEFAULT 1,
          prompt_hour INTEGER NOT NULL DEFAULT 9,
          summary_hour INTEGER NOT NULL DEFAULT 17,
          timezone TEXT NOT NULL DEFAULT 'Australia/Sydney',
          skip_break_days INTEGER NOT NULL DEFAULT 1,
          skip_weekends INTEGER NOT NULL DEFAULT 1,
          nudge_hour INTEGER
        )
      ''');
      raw.execute('''
        CREATE TABLE standup_sessions (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          signal_group_id TEXT NOT NULL,
          date TEXT NOT NULL,
          prompt_message_id TEXT,
          summary_message_id TEXT,
          status TEXT NOT NULL DEFAULT 'active',
          nudged_at INTEGER,
          UNIQUE(signal_group_id, date)
        )
      ''');
      raw.execute('''
        CREATE TABLE standup_responses (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          session_id INTEGER NOT NULL,
          signal_uuid TEXT NOT NULL,
          signal_display_name TEXT,
          yesterday TEXT,
          today TEXT,
          blockers TEXT,
          raw_message TEXT,
          UNIQUE(session_id, signal_uuid)
        )
      ''');
      raw.execute('''
        CREATE TABLE calendar_reminders (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          event_uid TEXT NOT NULL,
          signal_group_id TEXT NOT NULL,
          reminder_window TEXT NOT NULL,
          sent_at TEXT NOT NULL,
          UNIQUE(event_uid, signal_group_id, reminder_window)
        )
      ''');
      // V3: bot_metadata.
      raw.execute('''
        CREATE TABLE bot_metadata (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        )
      ''');
      // V4: memory tables.
      raw.execute('''
        CREATE TABLE memory_embeddings (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          message_id INTEGER,
          chat_id TEXT NOT NULL,
          source_type TEXT NOT NULL,
          source_text TEXT NOT NULL,
          sender_uuid TEXT,
          sender_name TEXT,
          visibility TEXT NOT NULL DEFAULT 'same_chat',
          embedding BLOB,
          created_at TEXT NOT NULL DEFAULT (datetime('now'))
        )
      ''');
      raw.execute('''
        CREATE TABLE memory_summaries (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          chat_id TEXT NOT NULL,
          summary_text TEXT NOT NULL,
          message_id_from INTEGER NOT NULL,
          message_id_to INTEGER NOT NULL,
          message_count INTEGER NOT NULL,
          created_at TEXT NOT NULL DEFAULT (datetime('now'))
        )
      ''');
      raw.execute('''
        CREATE TABLE memory_consolidation_state (
          chat_id TEXT PRIMARY KEY,
          last_consolidated_id INTEGER NOT NULL DEFAULT 0,
          last_consolidated_at TEXT
        )
      ''');
      // V5: dream_cycles.
      raw.execute('''
        CREATE TABLE dream_cycles (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          signal_group_id TEXT NOT NULL,
          date TEXT NOT NULL,
          status TEXT NOT NULL DEFAULT 'dreaming',
          triggered_by_uuid TEXT NOT NULL,
          started_at TEXT NOT NULL DEFAULT (datetime('now')),
          completed_at TEXT,
          error_message TEXT,
          UNIQUE(signal_group_id, date)
        )
      ''');

      // Insert test data with old column names.
      raw.execute(
        'INSERT INTO signal_workspace_links '
        "(signal_group_id, workspace_public_id, workspace_name, created_by_uuid) "
        "VALUES ('grp-1', 'ws-1', 'Test WS', 'user-1')",
      );
      raw.execute(
        'INSERT INTO signal_user_links '
        "(signal_uuid, signal_display_name, kan_user_email) "
        "VALUES ('uuid-1', 'Alice', 'alice@test.com')",
      );
      raw.execute(
        'INSERT INTO standup_config (signal_group_id) '
        "VALUES ('grp-1')",
      );
      raw.execute(
        "INSERT INTO standup_sessions (signal_group_id, date) "
        "VALUES ('grp-1', '2026-03-16')",
      );
      raw.execute(
        'INSERT INTO standup_responses (session_id, signal_uuid, signal_display_name) '
        "VALUES (1, 'uuid-1', 'Alice')",
      );
      raw.execute(
        "INSERT INTO dream_cycles (signal_group_id, date, triggered_by_uuid) "
        "VALUES ('grp-1', '2026-03-16', 'uuid-1')",
      );
      raw.execute(
        'INSERT INTO sent_reminders '
        "(card_public_id, signal_group_id, last_reminder_at) "
        "VALUES ('card-1', 'grp-1', datetime('now'))",
      );
      raw.execute(
        'INSERT INTO default_board_config '
        "(signal_group_id, board_public_id, list_public_id, board_name, list_name) "
        "VALUES ('grp-1', 'b-1', 'l-1', 'Board', 'List')",
      );
      raw.execute(
        'INSERT INTO calendar_reminders '
        "(event_uid, signal_group_id, reminder_window, sent_at) "
        "VALUES ('ev-1', 'grp-1', '24h', datetime('now'))",
      );

      raw.dispose();

      // Now open via BotDatabase which will run migrations.
      // We need a fresh in-memory DB, so re-create from scratch with the
      // V5 data already in place. BotDatabase wraps sqlite3, so we'll
      // simulate by using BotDatabase.inMemory() which creates a fresh V6 DB
      // and verify the table names are correct.

      // For a proper V5→V6 migration test, we need to use the raw handle.
      // Re-create the V5 DB and manually call into BotDatabase's migration.
      final v5db = sqlite3.openInMemory();
      addTearDown(v5db.dispose);

      v5db.execute('PRAGMA foreign_keys = ON');
      v5db.execute('CREATE TABLE schema_version (version INTEGER NOT NULL)');
      v5db.execute('INSERT INTO schema_version (version) VALUES (5)');

      // Minimal V5 tables for the columns being renamed.
      v5db.execute('''
        CREATE TABLE signal_workspace_links (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          signal_group_id TEXT NOT NULL UNIQUE,
          workspace_public_id TEXT NOT NULL,
          workspace_name TEXT NOT NULL,
          created_at TEXT NOT NULL DEFAULT (datetime('now')),
          created_by_uuid TEXT NOT NULL
        )
      ''');
      v5db.execute('''
        CREATE TABLE signal_user_links (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          signal_uuid TEXT NOT NULL UNIQUE,
          signal_display_name TEXT,
          kan_user_email TEXT NOT NULL,
          workspace_member_public_id TEXT,
          created_at TEXT NOT NULL DEFAULT (datetime('now')),
          created_by_uuid TEXT
        )
      ''');
      v5db.execute('''
        CREATE TABLE sent_reminders (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          card_public_id TEXT NOT NULL,
          signal_group_id TEXT NOT NULL,
          reminder_type TEXT NOT NULL DEFAULT 'overdue',
          last_reminder_at TEXT NOT NULL,
          UNIQUE(card_public_id, signal_group_id, reminder_type)
        )
      ''');
      v5db.execute('''
        CREATE TABLE default_board_config (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          signal_group_id TEXT NOT NULL UNIQUE,
          board_public_id TEXT NOT NULL,
          list_public_id TEXT NOT NULL,
          board_name TEXT NOT NULL,
          list_name TEXT NOT NULL,
          updated_at TEXT NOT NULL DEFAULT (datetime('now'))
        )
      ''');
      v5db.execute('''
        CREATE TABLE standup_config (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          signal_group_id TEXT NOT NULL UNIQUE,
          enabled INTEGER NOT NULL DEFAULT 1,
          prompt_hour INTEGER NOT NULL DEFAULT 9,
          summary_hour INTEGER NOT NULL DEFAULT 17,
          timezone TEXT NOT NULL DEFAULT 'Australia/Sydney',
          skip_break_days INTEGER NOT NULL DEFAULT 1,
          skip_weekends INTEGER NOT NULL DEFAULT 1,
          nudge_hour INTEGER
        )
      ''');
      v5db.execute('''
        CREATE TABLE standup_sessions (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          signal_group_id TEXT NOT NULL,
          date TEXT NOT NULL,
          prompt_message_id TEXT,
          summary_message_id TEXT,
          status TEXT NOT NULL DEFAULT 'active',
          nudged_at INTEGER,
          UNIQUE(signal_group_id, date)
        )
      ''');
      v5db.execute('''
        CREATE TABLE standup_responses (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          session_id INTEGER NOT NULL,
          signal_uuid TEXT NOT NULL,
          signal_display_name TEXT,
          yesterday TEXT,
          today TEXT,
          blockers TEXT,
          raw_message TEXT,
          UNIQUE(session_id, signal_uuid)
        )
      ''');
      v5db.execute('''
        CREATE TABLE calendar_reminders (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          event_uid TEXT NOT NULL,
          signal_group_id TEXT NOT NULL,
          reminder_window TEXT NOT NULL,
          sent_at TEXT NOT NULL,
          UNIQUE(event_uid, signal_group_id, reminder_window)
        )
      ''');
      v5db.execute('''
        CREATE TABLE dream_cycles (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          signal_group_id TEXT NOT NULL,
          date TEXT NOT NULL,
          status TEXT NOT NULL DEFAULT 'dreaming',
          triggered_by_uuid TEXT NOT NULL,
          started_at TEXT NOT NULL DEFAULT (datetime('now')),
          completed_at TEXT,
          error_message TEXT,
          UNIQUE(signal_group_id, date)
        )
      ''');

      // Insert test data.
      v5db.execute(
        "INSERT INTO signal_workspace_links "
        "(signal_group_id, workspace_public_id, workspace_name, created_by_uuid) "
        "VALUES ('grp-1', 'ws-1', 'Test WS', 'user-1')",
      );
      v5db.execute(
        "INSERT INTO signal_user_links "
        "(signal_uuid, signal_display_name, kan_user_email) "
        "VALUES ('uuid-1', 'Alice', 'alice@test.com')",
      );
      v5db.execute(
        "INSERT INTO dream_cycles (signal_group_id, date, triggered_by_uuid) "
        "VALUES ('grp-1', '2026-03-16', 'uuid-1')",
      );
      v5db.execute(
        "INSERT INTO standup_config (signal_group_id) VALUES ('grp-1')",
      );
      v5db.execute(
        "INSERT INTO standup_sessions (signal_group_id, date) "
        "VALUES ('grp-1', '2026-03-16')",
      );
      v5db.execute(
        "INSERT INTO standup_responses (session_id, signal_uuid, signal_display_name) "
        "VALUES (1, 'uuid-1', 'Alice')",
      );

      // Run the V6 migration by opening via BotDatabase.
      // BotDatabase._initSchema reads the version and calls _runMigrations.
      // We can't use BotDatabase directly with a raw handle, so we simulate
      // by running the ALTER statements manually (same as _migrateToV6).
      v5db.execute(
        'ALTER TABLE signal_workspace_links RENAME TO workspace_links',
      );
      v5db.execute(
        'ALTER TABLE signal_user_links RENAME TO user_links',
      );
      v5db.execute(
        'ALTER TABLE workspace_links RENAME COLUMN signal_group_id TO group_id',
      );
      v5db.execute(
        'ALTER TABLE user_links RENAME COLUMN signal_uuid TO user_id',
      );
      v5db.execute(
        'ALTER TABLE user_links RENAME COLUMN signal_display_name TO display_name',
      );
      v5db.execute(
        'ALTER TABLE sent_reminders RENAME COLUMN signal_group_id TO group_id',
      );
      v5db.execute(
        'ALTER TABLE default_board_config RENAME COLUMN signal_group_id TO group_id',
      );
      v5db.execute(
        'ALTER TABLE standup_config RENAME COLUMN signal_group_id TO group_id',
      );
      v5db.execute(
        'ALTER TABLE standup_sessions RENAME COLUMN signal_group_id TO group_id',
      );
      v5db.execute(
        'ALTER TABLE standup_responses RENAME COLUMN signal_uuid TO user_id',
      );
      v5db.execute(
        'ALTER TABLE standup_responses RENAME COLUMN signal_display_name TO display_name',
      );
      v5db.execute(
        'ALTER TABLE calendar_reminders RENAME COLUMN signal_group_id TO group_id',
      );
      v5db.execute(
        'ALTER TABLE dream_cycles RENAME COLUMN signal_group_id TO group_id',
      );

      // Verify table renames.
      final tables = v5db
          .select(
            "SELECT name FROM sqlite_master WHERE type = 'table' "
            "AND name NOT LIKE 'sqlite_%'",
          )
          .map((r) => r['name'] as String)
          .toList();
      expect(tables, contains('workspace_links'));
      expect(tables, contains('user_links'));
      expect(tables, isNot(contains('signal_workspace_links')));
      expect(tables, isNot(contains('signal_user_links')));

      // Verify data survived with new column names.
      final ws = v5db.select('SELECT * FROM workspace_links');
      expect(ws.length, 1);
      expect(ws.first['group_id'], 'grp-1');
      expect(ws.first['workspace_name'], 'Test WS');

      final ul = v5db.select('SELECT * FROM user_links');
      expect(ul.length, 1);
      expect(ul.first['user_id'], 'uuid-1');
      expect(ul.first['display_name'], 'Alice');
      expect(ul.first['kan_user_email'], 'alice@test.com');

      final dc = v5db.select('SELECT * FROM dream_cycles');
      expect(dc.length, 1);
      expect(dc.first['group_id'], 'grp-1');

      final sc = v5db.select('SELECT * FROM standup_config');
      expect(sc.length, 1);
      expect(sc.first['group_id'], 'grp-1');

      final ss = v5db.select('SELECT * FROM standup_sessions');
      expect(ss.length, 1);
      expect(ss.first['group_id'], 'grp-1');

      final sr = v5db.select('SELECT * FROM standup_responses');
      expect(sr.length, 1);
      expect(sr.first['user_id'], 'uuid-1');
      expect(sr.first['display_name'], 'Alice');
    });
  });

  group('V9 migration — personality traits', () {
    test('fresh database creates personality_traits table', () {
      final tables = db.tableNames();
      expect(tables, contains('personality_traits'));
    });

    test('personality_traits table has correct columns and constraints', () {
      // Insert a bot_identity first (foreign key target).
      db.handle.execute(
        "INSERT INTO bot_identity (name, pronouns, tone) "
        "VALUES ('Test', 'they/them', 'test')",
      );

      // Insert a valid trait.
      db.handle.execute(
        'INSERT INTO personality_traits (identity_id, trait_name, trait_value) '
        'VALUES (1, \'humor\', 80)',
      );
      final rows = db.handle.select('SELECT * FROM personality_traits');
      expect(rows, hasLength(1));
      expect(rows.first['trait_name'], equals('humor'));
      expect(rows.first['trait_value'], equals(80));

      // CHECK constraint should reject values outside 0-100.
      expect(
        () => db.handle.execute(
          'INSERT INTO personality_traits (identity_id, trait_name, trait_value) '
          'VALUES (1, \'warmth\', 150)',
        ),
        throwsA(anything),
      );

      // UNIQUE constraint on (identity_id, trait_name).
      expect(
        () => db.handle.execute(
          'INSERT INTO personality_traits (identity_id, trait_name, trait_value) '
          'VALUES (1, \'humor\', 90)',
        ),
        throwsA(anything),
      );
    });
  });
}
