/// General-purpose bot metadata queries (key-value store).
library;

import '../database.dart';

/// Mixin providing get/set access to the `bot_metadata` table.
mixin MetadataQueries {
  /// The database handle. Provided by the mixing-in class.
  BotDatabase get db;

  /// Returns the value for [key], or `null` if not set.
  String? getMetadata(String key) {
    final rows = db.handle.select(
      'SELECT value FROM bot_metadata WHERE key = ?',
      [key],
    );
    if (rows.isEmpty) return null;
    return rows.first['value'] as String;
  }

  /// Stores or updates a metadata [key]/[value] pair.
  void setMetadata(String key, String value) {
    db.handle.execute(
      'INSERT INTO bot_metadata (key, value) VALUES (?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      [key, value],
    );
  }
}
