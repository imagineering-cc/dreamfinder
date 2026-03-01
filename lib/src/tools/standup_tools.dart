/// Custom tools for standup orchestration.
///
/// - `configure_standup`: Enable/configure standups for a group (admin-only).
/// - `get_standup_config`: Read the current standup config for a group.
/// - `submit_standup_response`: Record a user's standup response for today.
/// - `get_standup_summary`: Retrieve all responses for today's standup session.
library;

import 'dart:convert';

import '../agent/tool_registry.dart';
import '../db/queries.dart';

/// Registers standup tools with the [ToolRegistry].
void registerStandupTools(ToolRegistry registry, Queries queries) {
  registry.registerCustomTool(_configureStandupTool(queries));
  registry.registerCustomTool(_getStandupConfigTool(queries));
  registry.registerCustomTool(_submitStandupResponseTool(queries));
  registry.registerCustomTool(_getStandupSummaryTool(queries));
}

CustomToolDef _configureStandupTool(Queries queries) {
  return CustomToolDef(
    name: 'configure_standup',
    description: 'Enable or configure daily standups for a Signal group. '
        'Sets the prompt hour, summary hour, timezone, and weekend/break-day '
        'skipping. Admin-only.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'signal_group_id': <String, dynamic>{
          'type': 'string',
          'description': 'The Signal group ID.',
        },
        'enabled': <String, dynamic>{
          'type': 'boolean',
          'description': 'Whether standups are enabled (default: true).',
        },
        'prompt_hour': <String, dynamic>{
          'type': 'integer',
          'description':
              'Hour (0-23) to send the standup prompt (default: 9).',
        },
        'summary_hour': <String, dynamic>{
          'type': 'integer',
          'description':
              'Hour (0-23) to send the standup summary (default: 17).',
        },
        'timezone': <String, dynamic>{
          'type': 'string',
          'description':
              'IANA timezone for scheduling (default: Australia/Sydney). '
              'Note: stored but not yet applied — prompts currently use '
              'server-local time.',
        },
        'skip_weekends': <String, dynamic>{
          'type': 'boolean',
          'description': 'Skip standups on weekends (default: true).',
        },
      },
      'required': <String>['signal_group_id'],
    },
    requiresAdmin: true,
    handler: (args) async {
      final groupId = args['signal_group_id'] as String;

      queries.upsertStandupConfig(
        signalGroupId: groupId,
        enabled: args['enabled'] as bool?,
        promptHour: args['prompt_hour'] as int?,
        summaryHour: args['summary_hour'] as int?,
        timezone: args['timezone'] as String?,
        skipWeekends: args['skip_weekends'] as bool?,
      );

      final config = queries.getStandupConfig(groupId);
      return jsonEncode(<String, dynamic>{
        'success': true,
        'enabled': config!.enabled,
        'prompt_hour': config.promptHour,
        'summary_hour': config.summaryHour,
        'timezone': config.timezone,
        'skip_weekends': config.skipWeekends,
      });
    },
  );
}

CustomToolDef _getStandupConfigTool(Queries queries) {
  return CustomToolDef(
    name: 'get_standup_config',
    description: 'Get the standup configuration for a Signal group.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'signal_group_id': <String, dynamic>{
          'type': 'string',
          'description': 'The Signal group ID.',
        },
      },
      'required': <String>['signal_group_id'],
    },
    handler: (args) async {
      final config =
          queries.getStandupConfig(args['signal_group_id'] as String);
      if (config == null) {
        return jsonEncode(<String, dynamic>{
          'configured': false,
        });
      }

      return jsonEncode(<String, dynamic>{
        'configured': true,
        'enabled': config.enabled,
        'prompt_hour': config.promptHour,
        'summary_hour': config.summaryHour,
        'timezone': config.timezone,
        'skip_weekends': config.skipWeekends,
        'skip_break_days': config.skipBreakDays,
        'nudge_hour': config.nudgeHour,
      });
    },
  );
}

CustomToolDef _submitStandupResponseTool(Queries queries) {
  return CustomToolDef(
    name: 'submit_standup_response',
    description: 'Record a standup response from a team member. Creates '
        "today's standup session if it doesn't exist yet. The agent should "
        'call this when it recognizes a standup update in the conversation.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'signal_group_id': <String, dynamic>{
          'type': 'string',
          'description': 'The Signal group ID.',
        },
        'signal_uuid': <String, dynamic>{
          'type': 'string',
          'description': 'The Signal UUID of the team member.',
        },
        'signal_display_name': <String, dynamic>{
          'type': 'string',
          'description': 'The team member\'s display name.',
        },
        'yesterday': <String, dynamic>{
          'type': 'string',
          'description': 'What they accomplished yesterday.',
        },
        'today': <String, dynamic>{
          'type': 'string',
          'description': 'What they plan to work on today.',
        },
        'blockers': <String, dynamic>{
          'type': 'string',
          'description': 'Any blockers or impediments.',
        },
        'raw_message': <String, dynamic>{
          'type': 'string',
          'description':
              'The original message text before parsing into fields.',
        },
      },
      'required': <String>['signal_group_id', 'signal_uuid'],
    },
    handler: (args) async {
      final groupId = args['signal_group_id'] as String;
      final today = DateTime.now().toIso8601String().substring(0, 10);

      // Ensure a session exists for today.
      var session = queries.getActiveStandupSession(groupId, today);
      if (session == null) {
        queries.createStandupSession(
          signalGroupId: groupId,
          date: today,
        );
        session = queries.getActiveStandupSession(groupId, today);
      }

      queries.upsertStandupResponse(
        sessionId: session!.id,
        signalUuid: args['signal_uuid'] as String,
        signalDisplayName: args['signal_display_name'] as String?,
        yesterday: args['yesterday'] as String?,
        today: args['today'] as String?,
        blockers: args['blockers'] as String?,
        rawMessage: args['raw_message'] as String?,
      );

      return jsonEncode(<String, dynamic>{
        'success': true,
        'session_date': today,
      });
    },
  );
}

CustomToolDef _getStandupSummaryTool(Queries queries) {
  return CustomToolDef(
    name: 'get_standup_summary',
    description: "Get all standup responses for today's session in a group. "
        'Useful for generating a standup summary or checking who has responded.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'signal_group_id': <String, dynamic>{
          'type': 'string',
          'description': 'The Signal group ID.',
        },
        'date': <String, dynamic>{
          'type': 'string',
          'description':
              'Date in YYYY-MM-DD format (default: today).',
        },
      },
      'required': <String>['signal_group_id'],
    },
    handler: (args) async {
      final groupId = args['signal_group_id'] as String;
      final date = args['date'] as String? ??
          DateTime.now().toIso8601String().substring(0, 10);

      final session = queries.getActiveStandupSession(groupId, date);
      if (session == null) {
        return jsonEncode(<String, dynamic>{
          'has_session': false,
          'date': date,
        });
      }

      final responses = queries.getStandupResponses(session.id);
      return jsonEncode(<String, dynamic>{
        'has_session': true,
        'date': date,
        'status': session.status.dbValue,
        'response_count': responses.length,
        'responses': <Map<String, dynamic>>[
          for (final r in responses)
            <String, dynamic>{
              'signal_uuid': r.signalUuid,
              'display_name': r.signalDisplayName,
              'yesterday': r.yesterday,
              'today': r.today,
              'blockers': r.blockers,
            },
        ],
      });
    },
  );
}
