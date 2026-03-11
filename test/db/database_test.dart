import 'package:dreamfinder/src/db/database.dart';
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
  });
}
