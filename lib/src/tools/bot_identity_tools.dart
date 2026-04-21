/// Custom tools for managing the bot's identity (name, pronouns, tone).
///
/// - `get_bot_identity`: Returns the current identity (latest from DB, or defaults).
/// - `set_bot_identity`: Saves a new identity record (admin-only by convention).
library;

import 'dart:convert';

import '../agent/tool_registry.dart';
import '../db/queries.dart';

/// Default identity used when no record exists in the database.
const defaultBotName = 'Dreamfinder';
const defaultPronouns = 'they/them';
const defaultTone = 'Short, blunt, dry. Pub-register wit';

/// The five canonical personality trait axes.
const knownTraitNames = {
  'directness',
  'warmth',
  'humor',
  'formality',
  'chaos',
};

/// Callback invoked after a successful `set_bot_identity` so callers can
/// refresh caches (e.g., the bot-name mention regex in the main loop).
void Function()? _onIdentityChanged;

/// Registers a callback that fires whenever the bot identity changes.
void registerBotIdentityOnChanged(void Function() callback) {
  _onIdentityChanged = callback;
}

/// Registers bot identity tools with the [ToolRegistry].
void registerBotIdentityTools(ToolRegistry registry, Queries queries) {
  registry.registerCustomTool(_getIdentityTool(queries));
  registry.registerCustomTool(_setIdentityTool(queries));
  registry.registerCustomTool(_adjustTraitTool(queries));
}

CustomToolDef _getIdentityTool(Queries queries) {
  return CustomToolDef(
    name: 'get_bot_identity',
    description: 'Get the bot\'s current identity (name, pronouns, tone). '
        'Returns the most recently set identity, or defaults if none has been set.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
      'required': <String>[],
    },
    handler: (args) async {
      final identity = queries.getBotIdentity();
      Map<String, int>? traitsMap;
      if (identity != null) {
        final traits = queries.getPersonalityTraits(identity.id);
        if (traits.isNotEmpty) {
          traitsMap = {for (final t in traits) t.name: t.value};
        }
      }
      return jsonEncode(<String, dynamic>{
        'name': identity?.name ?? defaultBotName,
        'pronouns': identity?.pronouns ?? defaultPronouns,
        'tone': identity?.tone ?? defaultTone,
        'tone_description': identity?.toneDescription,
        'chosen_at': identity?.chosenAt,
        'chosen_in_group_id': identity?.chosenInGroupId,
        'traits': traitsMap,
      });
    },
  );
}

CustomToolDef _setIdentityTool(Queries queries) {
  return CustomToolDef(
    requiresAdmin: true,
    name: 'set_bot_identity',
    description: 'Set the bot\'s identity. Admin-only — updates the name, '
        'pronouns, and communication tone. The new identity takes effect '
        'immediately for all chats.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'name': <String, dynamic>{
          'type': 'string',
          'description': 'The bot\'s display name.',
        },
        'pronouns': <String, dynamic>{
          'type': 'string',
          'description': 'Pronouns (e.g. "they/them", "she/her", "he/him").',
        },
        'tone': <String, dynamic>{
          'type': 'string',
          'description':
              'Communication tone (e.g. "playful", "formal", "sarcastic").',
        },
        'tone_description': <String, dynamic>{
          'type': 'string',
          'description': 'Optional longer description of the tone.',
        },
        'chosen_in_group_id': <String, dynamic>{
          'type': 'string',
          'description': 'The group ID where this identity was chosen.',
        },
        'traits': <String, dynamic>{
          'type': 'object',
          'description':
              'Personality trait proportions (0-100). TARS-style blending. '
              'Keys: directness, warmth, humor, formality, chaos. '
              'Example: {"directness": 85, "warmth": 30, "humor": 80, '
              '"formality": 10, "chaos": 60}',
          'additionalProperties': <String, dynamic>{
            'type': 'integer',
            'minimum': 0,
            'maximum': 100,
          },
        },
      },
      'required': <String>['name', 'pronouns', 'tone'],
    },
    handler: (args) async {
      final name = args['name'] as String;
      final pronouns = args['pronouns'] as String;
      final tone = args['tone'] as String;
      final toneDescription = args['tone_description'] as String?;
      final chosenInGroupId = args['chosen_in_group_id'] as String?;
      final rawTraits = args['traits'] as Map<String, dynamic>?;

      queries.saveBotIdentity(
        name: name,
        pronouns: pronouns,
        tone: tone,
        toneDescription: toneDescription,
        chosenInGroupId: chosenInGroupId,
      );

      Map<String, int>? savedTraits;
      List<String>? traitWarnings;
      if (rawTraits != null && rawTraits.isNotEmpty) {
        final traits = rawTraits.map(
          (k, v) => MapEntry(k, (v as num).toInt()),
        );
        final unknown = traits.keys
            .where((k) => !knownTraitNames.contains(k))
            .toList();
        if (unknown.isNotEmpty) {
          traitWarnings = unknown
              .map((k) => 'Unknown trait "$k" — known traits are: '
                  '${knownTraitNames.join(', ')}')
              .toList();
        }
        final identity = queries.getBotIdentity()!;
        queries.savePersonalityTraits(identity.id, traits);
        savedTraits = traits;
      }

      _onIdentityChanged?.call();

      return jsonEncode(<String, dynamic>{
        'success': true,
        'name': name,
        'pronouns': pronouns,
        'tone': tone,
        if (savedTraits != null) 'traits': savedTraits,
        if (traitWarnings != null) 'trait_warnings': traitWarnings,
      });
    },
  );
}

CustomToolDef _adjustTraitTool(Queries queries) {
  return CustomToolDef(
    name: 'adjust_trait',
    description: 'Adjust a single personality trait in real time. '
        'Anyone can use this — no admin required. The change takes '
        'effect immediately on the next message. '
        'Known traits: directness, warmth, humor, formality, chaos.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'trait_name': <String, dynamic>{
          'type': 'string',
          'description': 'The trait to adjust '
              '(directness, warmth, humor, formality, chaos).',
        },
        'value': <String, dynamic>{
          'type': 'integer',
          'description': 'New value from 0 to 100.',
          'minimum': 0,
          'maximum': 100,
        },
      },
      'required': <String>['trait_name', 'value'],
    },
    handler: (args) async {
      final traitName = args['trait_name'] as String;
      final value = (args['value'] as num).toInt();

      final identity = queries.getBotIdentity();
      if (identity == null) {
        return jsonEncode(<String, dynamic>{
          'error': 'No identity set. Run a naming ceremony first.',
        });
      }

      // Read current traits, update the one requested.
      final currentTraits = queries.getPersonalityTraits(identity.id);
      final traitMap = {for (final t in currentTraits) t.name: t.value};
      final oldValue = traitMap[traitName];
      traitMap[traitName] = value;

      queries.savePersonalityTraits(identity.id, traitMap);

      String? warning;
      if (!knownTraitNames.contains(traitName)) {
        warning = 'Unknown trait "$traitName" — known traits are: '
            '${knownTraitNames.join(', ')}';
      }

      return jsonEncode(<String, dynamic>{
        'success': true,
        'trait_name': traitName,
        'old_value': oldValue,
        'new_value': value,
        if (warning != null) 'warning': warning,
      });
    },
  );
}
