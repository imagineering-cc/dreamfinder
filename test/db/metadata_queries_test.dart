import 'package:dreamfinder/src/db/database.dart';
import 'package:dreamfinder/src/db/queries.dart';
import 'package:test/test.dart';

void main() {
  late BotDatabase db;
  late Queries queries;

  setUp(() {
    db = BotDatabase.inMemory();
    queries = Queries(db);
  });

  tearDown(() => db.close());

  group('MetadataQueries', () {
    test('getMetadata returns null for missing key', () {
      expect(queries.getMetadata('nonexistent'), isNull);
    });

    test('setMetadata stores and retrieves a value', () {
      queries.setMetadata('last_deployed_version', 'v1.0+abc123');
      expect(queries.getMetadata('last_deployed_version'), 'v1.0+abc123');
    });

    test('setMetadata upserts on conflict', () {
      queries.setMetadata('key', 'first');
      queries.setMetadata('key', 'second');
      expect(queries.getMetadata('key'), 'second');
    });

    test('stores multiple independent keys', () {
      queries.setMetadata('a', '1');
      queries.setMetadata('b', '2');
      expect(queries.getMetadata('a'), '1');
      expect(queries.getMetadata('b'), '2');
    });
  });
}
