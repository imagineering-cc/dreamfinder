/// Personality trait queries — TARS-style proportional personality blending.
///
/// Traits are 0–100 values on independent axes (directness, warmth, humor,
/// formality, chaos) tied to a [BotIdentityRecord]. Enables proportional
/// personality mixing instead of single-choice selection.
library;

import '../database.dart';
import '../schema.dart';

/// Mixin providing personality trait CRUD operations.
mixin PersonalityQueries {
  /// The database handle. Provided by the mixing-in class.
  BotDatabase get db;

  /// Returns all personality traits for the given [identityId].
  ///
  /// Returns an empty list if no traits have been set.
  List<PersonalityTrait> getPersonalityTraits(int identityId) {
    final rows = db.handle.select(
      'SELECT trait_name, trait_value FROM personality_traits '
      'WHERE identity_id = ? ORDER BY trait_name',
      [identityId],
    );
    return rows.map(_traitFromRow).toList();
  }

  /// Saves personality traits for the given [identityId].
  ///
  /// Replaces all existing traits — this is a full overwrite, not a merge.
  /// Each value in [traits] must be between 0 and 100 (enforced by the
  /// CHECK constraint in the schema).
  void savePersonalityTraits(int identityId, Map<String, int> traits) {
    db.handle.execute(
      'DELETE FROM personality_traits WHERE identity_id = ?',
      [identityId],
    );
    for (final entry in traits.entries) {
      db.handle.execute(
        'INSERT INTO personality_traits (identity_id, trait_name, trait_value) '
        'VALUES (?, ?, ?)',
        [identityId, entry.key, entry.value],
      );
    }
  }

  PersonalityTrait _traitFromRow(Map<String, Object?> row) {
    return PersonalityTrait(
      name: row['trait_name']! as String,
      value: row['trait_value']! as int,
    );
  }
}
