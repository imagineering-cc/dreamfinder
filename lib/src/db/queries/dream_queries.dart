/// Dream cycle queries — tracking autonomous nightly knowledge sessions.
library;

import '../database.dart';
import '../schema.dart';

/// Mixin providing dream cycle CRUD operations.
mixin DreamQueries {
  /// The database handle. Provided by the mixing-in class.
  BotDatabase get db;

  /// Returns the dream cycle for [signalGroupId] on [date], or `null`.
  DreamCycleRecord? getDreamCycle(String signalGroupId, String date) {
    final rows = db.handle.select(
      'SELECT * FROM dream_cycles '
      'WHERE signal_group_id = ? AND date = ?',
      [signalGroupId, date],
    );
    if (rows.isEmpty) return null;
    return _dreamCycleFromRow(rows.first);
  }

  /// Returns the most recently completed dream cycle for [signalGroupId],
  /// or `null` if no cycle has ever completed.
  DreamCycleRecord? getLastCompletedDreamCycle(String signalGroupId) {
    final rows = db.handle.select(
      'SELECT * FROM dream_cycles '
      "WHERE signal_group_id = ? AND status = 'completed' "
      'ORDER BY started_at DESC LIMIT 1',
      [signalGroupId],
    );
    if (rows.isEmpty) return null;
    return _dreamCycleFromRow(rows.first);
  }

  /// Creates a new dream cycle row. Returns the row ID.
  int createDreamCycle({
    required String signalGroupId,
    required String date,
    required String triggeredByUuid,
  }) {
    db.handle.execute(
      'INSERT INTO dream_cycles '
      '(signal_group_id, date, triggered_by_uuid) '
      'VALUES (?, ?, ?)',
      [signalGroupId, date, triggeredByUuid],
    );
    return db.handle.lastInsertRowId;
  }

  /// Updates fields on an existing dream cycle.
  void updateDreamCycle(
    int id, {
    DreamCycleStatus? status,
    String? completedAt,
    String? errorMessage,
  }) {
    final sets = <String>[];
    final params = <Object?>[];

    if (status != null) {
      sets.add('status = ?');
      params.add(status.dbValue);
    }
    if (completedAt != null) {
      sets.add('completed_at = ?');
      params.add(completedAt);
    }
    if (errorMessage != null) {
      sets.add('error_message = ?');
      params.add(errorMessage);
    }

    if (sets.isEmpty) return;

    params.add(id);
    db.handle.execute(
      'UPDATE dream_cycles SET ${sets.join(', ')} WHERE id = ?',
      params,
    );
  }

  DreamCycleRecord _dreamCycleFromRow(Map<String, Object?> row) {
    return DreamCycleRecord(
      id: row['id']! as int,
      signalGroupId: row['signal_group_id']! as String,
      date: row['date']! as String,
      status: DreamCycleStatus.fromDb(row['status']! as String),
      triggeredByUuid: row['triggered_by_uuid']! as String,
      startedAt: row['started_at']! as String,
      completedAt: row['completed_at'] as String?,
      errorMessage: row['error_message'] as String?,
    );
  }
}
