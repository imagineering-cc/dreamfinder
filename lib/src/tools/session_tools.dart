/// Custom tools for co-working session management.
///
/// - `start_session`: Start a co-working session in a group.
/// - `advance_session`: Advance the session to the next phase.
/// - `end_session`: End the session and post a summary.
/// - `capture_insight`: Capture an insight, decision, or action item.
library;

import 'dart:convert';

import '../agent/tool_registry.dart';
import '../session/session_state.dart';

/// Callback type for sending a message to a group.
typedef SendGroupMessage = Future<void> Function(
    String groupId, String message);

/// Registers session tools with the [ToolRegistry].
///
/// The [sendGroupMessage] callback is used by `end_session` to post the
/// session summary back to the group chat.
void registerSessionTools(
  ToolRegistry registry,
  SessionState state, {
  required SendGroupMessage sendGroupMessage,
}) {
  registry.registerCustomTool(_startSessionTool(state));
  registry.registerCustomTool(_advanceSessionTool(state));
  registry.registerCustomTool(_endSessionTool(state, sendGroupMessage));
  registry.registerCustomTool(_captureInsightTool(state));
}

CustomToolDef _startSessionTool(SessionState state) {
  return CustomToolDef(
    name: 'start_session',
    description: 'Start a co-working session in this group.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'group_id': <String, dynamic>{
          'type': 'string',
          'description': 'The group ID.',
        },
        'initiator_id': <String, dynamic>{
          'type': 'string',
          'description': 'The user ID of the person starting the session.',
        },
        'topic': <String, dynamic>{
          'type': 'string',
          'description': 'Optional session theme or focus area.',
        },
      },
      'required': <String>['group_id', 'initiator_id'],
    },
    handler: (args) async {
      final groupId = args['group_id'] as String;
      final initiatorId = args['initiator_id'] as String;
      final topic = args['topic'] as String?;

      final started = state.startSession(
        groupId,
        initiatorId: initiatorId,
      );

      if (!started) {
        return jsonEncode(<String, dynamic>{
          'success': false,
          'error': 'A session is already active in this group.',
        });
      }

      if (topic != null) {
        state.queries.setMetadata('session-topic::$groupId', topic);
      }

      return jsonEncode(<String, dynamic>{
        'success': true,
        'phase': SessionPhase.pitch.number,
        'phase_label': SessionPhase.pitch.label,
        if (topic != null) 'topic': topic,
      });
    },
  );
}

CustomToolDef _advanceSessionTool(SessionState state) {
  return CustomToolDef(
    name: 'advance_session',
    description: 'Advance the session to the next phase.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'group_id': <String, dynamic>{
          'type': 'string',
          'description': 'The group ID.',
        },
      },
      'required': <String>['group_id'],
    },
    handler: (args) async {
      final groupId = args['group_id'] as String;
      final nextPhase = state.advanceSession(groupId);

      if (nextPhase == null) {
        return jsonEncode(<String, dynamic>{
          'success': false,
          'error': 'No active session to advance, or already on the '
              'final phase (demo). Use end_session to wrap up.',
        });
      }

      return jsonEncode(<String, dynamic>{
        'success': true,
        'new_phase': nextPhase.number,
        'new_phase_label': nextPhase.label,
      });
    },
  );
}

CustomToolDef _endSessionTool(
  SessionState state,
  SendGroupMessage sendGroupMessage,
) {
  return CustomToolDef(
    name: 'end_session',
    description: 'End the current session and post a summary.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'group_id': <String, dynamic>{
          'type': 'string',
          'description': 'The group ID.',
        },
        'summary': <String, dynamic>{
          'type': 'string',
          'description': 'A recap of the session to post to the group.',
        },
      },
      'required': <String>['group_id', 'summary'],
    },
    handler: (args) async {
      final groupId = args['group_id'] as String;
      final summary = args['summary'] as String;

      if (!state.isSessionActive(groupId)) {
        return jsonEncode(<String, dynamic>{
          'success': false,
          'error': 'No active session to end.',
        });
      }

      state.endSession(groupId);

      try {
        await sendGroupMessage(groupId, summary);
        return jsonEncode(<String, dynamic>{
          'success': true,
          'message': 'Session ended and summary posted.',
        });
      } on Exception catch (e) {
        return jsonEncode(<String, dynamic>{
          'success': false,
          'error': 'Session ended but failed to post summary: $e',
        });
      }
    },
  );
}

CustomToolDef _captureInsightTool(SessionState state) {
  return CustomToolDef(
    name: 'capture_insight',
    description: 'Capture a notable insight, decision, or action item '
        'from the session.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'group_id': <String, dynamic>{
          'type': 'string',
          'description': 'The group ID.',
        },
        'insight': <String, dynamic>{
          'type': 'string',
          'description': 'The insight, decision, or action item text.',
        },
        'type': <String, dynamic>{
          'type': 'string',
          'enum': <String>['insight', 'decision', 'action_item', 'spark'],
          'description': 'The type of capture.',
        },
        'author': <String, dynamic>{
          'type': 'string',
          'description': 'Who contributed this insight (optional).',
        },
      },
      'required': <String>['group_id', 'insight', 'type'],
    },
    handler: (args) async {
      final groupId = args['group_id'] as String;
      final insight = args['insight'] as String;
      final type = args['type'] as String;
      final author = args['author'] as String?;

      if (!state.isSessionActive(groupId)) {
        return jsonEncode(<String, dynamic>{
          'success': false,
          'error': 'No active session to capture insights for.',
        });
      }

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final key = 'session-insight::$groupId::$timestamp';

      final payload = <String, dynamic>{
        'insight': insight,
        'type': type,
        if (author != null) 'author': author,
        'captured_at': DateTime.now().toUtc().toIso8601String(),
      };

      state.queries.setMetadata(key, jsonEncode(payload));

      return jsonEncode(<String, dynamic>{
        'success': true,
        'type': type,
      });
    },
  );
}
