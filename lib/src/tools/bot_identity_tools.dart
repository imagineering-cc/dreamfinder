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
      return jsonEncode(<String, dynamic>{
        'name': identity?.name ?? defaultBotName,
        'pronouns': identity?.pronouns ?? defaultPronouns,
        'tone': identity?.tone ?? defaultTone,
        'tone_description': identity?.toneDescription,
        'chosen_at': identity?.chosenAt,
        'chosen_in_group_id': identity?.chosenInGroupId,
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
      },
      'required': <String>['name', 'pronouns', 'tone'],
    },
    handler: (args) async {
      final name = args['name'] as String;
      final pronouns = args['pronouns'] as String;
      final tone = args['tone'] as String;
      final toneDescription = args['tone_description'] as String?;
      final chosenInGroupId = args['chosen_in_group_id'] as String?;

      queries.saveBotIdentity(
        name: name,
        pronouns: pronouns,
        tone: tone,
        toneDescription: toneDescription,
        chosenInGroupId: chosenInGroupId,
      );

      _onIdentityChanged?.call();

      return jsonEncode(<String, dynamic>{
        'success': true,
        'name': name,
        'pronouns': pronouns,
        'tone': tone,
      });
    },
  );
}
