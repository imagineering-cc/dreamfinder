/// Custom tools for kickstart onboarding flow.
///
/// - `advance_kickstart`: Move to the next kickstart step (agent-initiated).
/// - `complete_kickstart`: Mark kickstart as done (agent-initiated at step 5).
library;

import 'dart:convert';

import '../agent/tool_registry.dart';
import '../kickstart/kickstart_state.dart';

/// Registers kickstart tools with the [ToolRegistry].
void registerKickstartTools(ToolRegistry registry, KickstartState state) {
  registry.registerCustomTool(_advanceKickstartTool(state));
  registry.registerCustomTool(_completeKickstartTool(state));
}

CustomToolDef _advanceKickstartTool(KickstartState state) {
  return CustomToolDef(
    name: 'advance_kickstart',
    description: 'Advance the kickstart onboarding to the next step. '
        'Call this when the current step is complete (user confirmed, '
        'or said "done", "next", or "skip").',
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
      final groupId = args['signal_group_id'] as String;
      final nextStep = state.advanceKickstart(groupId);

      if (nextStep == null) {
        return jsonEncode(<String, dynamic>{
          'success': false,
          'error': 'No active kickstart to advance, or already on the '
              'final step. Use complete_kickstart to finish.',
        });
      }

      return jsonEncode(<String, dynamic>{
        'success': true,
        'new_step': nextStep.number,
        'new_step_label': nextStep.label,
      });
    },
  );
}

CustomToolDef _completeKickstartTool(KickstartState state) {
  return CustomToolDef(
    name: 'complete_kickstart',
    description: 'Mark the kickstart onboarding as complete. '
        'Call this at the end of Step 5 (Dream Primer) after '
        'summarizing the setup and introducing the dream cycle.',
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
      final groupId = args['signal_group_id'] as String;
      state.completeKickstart(groupId);

      return jsonEncode(<String, dynamic>{
        'success': true,
        'message': 'Kickstart complete! The group is fully onboarded.',
      });
    },
  );
}
