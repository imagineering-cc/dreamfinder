import 'dart:convert';

import 'package:dreamfinder/src/agent/tool_registry.dart';
import 'package:dreamfinder/src/db/database.dart';
import 'package:dreamfinder/src/db/queries.dart';
import 'package:dreamfinder/src/tools/standup_tools.dart';
import 'package:test/test.dart';

void main() {
  late BotDatabase db;
  late Queries queries;
  late ToolRegistry registry;

  setUp(() {
    db = BotDatabase.inMemory();
    queries = Queries(db);
    registry = ToolRegistry();
    registerStandupTools(registry, queries);
  });

  tearDown(() {
    db.close();
  });

  /// Helper to execute a tool and decode the JSON result.
  Future<Map<String, dynamic>> call(
    String toolName,
    Map<String, dynamic> args, {
    bool isAdmin = true,
  }) async {
    registry.setContext(ToolContext(
      senderUuid: 'uuid-sender',
      isAdmin: isAdmin,
      chatId: 'group-1',
    ));
    final result = await registry.executeTool(toolName, args);
    return jsonDecode(result) as Map<String, dynamic>;
  }

  group('configure_standup', () {
    test('creates default config for a group', () async {
      final result = await call('configure_standup', {
        'signal_group_id': 'group-1',
      });
      expect(result['success'], isTrue);

      final config = queries.getStandupConfig('group-1');
      expect(config, isNotNull);
      expect(config!.enabled, isTrue);
      expect(config.promptHour, equals(9));
      expect(config.summaryHour, equals(17));
    });

    test('updates existing config with partial fields', () async {
      await call('configure_standup', {
        'signal_group_id': 'group-1',
      });

      final result = await call('configure_standup', {
        'signal_group_id': 'group-1',
        'prompt_hour': 8,
        'summary_hour': 16,
        'timezone': 'US/Pacific',
      });
      expect(result['success'], isTrue);

      final config = queries.getStandupConfig('group-1');
      expect(config!.promptHour, equals(8));
      expect(config.summaryHour, equals(16));
      expect(config.timezone, equals('US/Pacific'));
    });

    test('can disable standup', () async {
      await call('configure_standup', {
        'signal_group_id': 'group-1',
      });

      final result = await call('configure_standup', {
        'signal_group_id': 'group-1',
        'enabled': false,
      });
      expect(result['success'], isTrue);

      final config = queries.getStandupConfig('group-1');
      expect(config!.enabled, isFalse);
    });

    test('rejects non-admin callers', () async {
      final result = await call(
        'configure_standup',
        {'signal_group_id': 'group-1'},
        isAdmin: false,
      );
      expect(result['error'], contains('admin'));
    });
  });

  group('get_standup_config', () {
    test('returns null fields when no config exists', () async {
      final result = await call('get_standup_config', {
        'signal_group_id': 'group-1',
      });
      expect(result['configured'], isFalse);
    });

    test('returns config when it exists', () async {
      queries.upsertStandupConfig(
        signalGroupId: 'group-1',
        promptHour: 10,
        summaryHour: 18,
        timezone: 'US/Eastern',
      );

      final result = await call('get_standup_config', {
        'signal_group_id': 'group-1',
      });
      expect(result['configured'], isTrue);
      expect(result['prompt_hour'], equals(10));
      expect(result['summary_hour'], equals(18));
      expect(result['timezone'], equals('US/Eastern'));
    });
  });

  group('submit_standup_response', () {
    test('creates a session and records response', () async {
      // Configure standup first.
      queries.upsertStandupConfig(signalGroupId: 'group-1');

      final result = await call('submit_standup_response', {
        'signal_group_id': 'group-1',
        'signal_uuid': 'uuid-alice',
        'signal_display_name': 'Alice',
        'yesterday': 'Finished the login flow',
        'today': 'Starting dashboard',
        'blockers': 'None',
      });
      expect(result['success'], isTrue);

      // Verify the response was recorded.
      final today = DateTime.now().toIso8601String().substring(0, 10);
      final session = queries.getActiveStandupSession('group-1', today);
      expect(session, isNotNull);

      final responses = queries.getStandupResponses(session!.id);
      expect(responses, hasLength(1));
      expect(responses.first.yesterday, equals('Finished the login flow'));
      expect(responses.first.today, equals('Starting dashboard'));
    });

    test('updates existing response from same user', () async {
      queries.upsertStandupConfig(signalGroupId: 'group-1');

      await call('submit_standup_response', {
        'signal_group_id': 'group-1',
        'signal_uuid': 'uuid-alice',
        'yesterday': 'Original',
        'today': 'Original',
      });

      await call('submit_standup_response', {
        'signal_group_id': 'group-1',
        'signal_uuid': 'uuid-alice',
        'yesterday': 'Updated',
        'today': 'Updated',
      });

      final today = DateTime.now().toIso8601String().substring(0, 10);
      final session = queries.getActiveStandupSession('group-1', today);
      final responses = queries.getStandupResponses(session!.id);
      expect(responses, hasLength(1));
      expect(responses.first.yesterday, equals('Updated'));
    });
  });

  group('get_standup_summary', () {
    test('returns empty when no session exists', () async {
      final result = await call('get_standup_summary', {
        'signal_group_id': 'group-1',
      });
      expect(result['has_session'], isFalse);
    });

    test('returns all responses for today', () async {
      queries.upsertStandupConfig(signalGroupId: 'group-1');

      // Submit two responses.
      await call('submit_standup_response', {
        'signal_group_id': 'group-1',
        'signal_uuid': 'uuid-alice',
        'signal_display_name': 'Alice',
        'yesterday': 'Login flow',
        'today': 'Dashboard',
      });

      await call('submit_standup_response', {
        'signal_group_id': 'group-1',
        'signal_uuid': 'uuid-bob',
        'signal_display_name': 'Bob',
        'yesterday': 'API tests',
        'today': 'Deployment',
        'blockers': 'Need staging access',
      });

      final result = await call('get_standup_summary', {
        'signal_group_id': 'group-1',
      });
      expect(result['has_session'], isTrue);
      expect(result['response_count'], equals(2));

      final responses = result['responses'] as List<dynamic>;
      expect(responses, hasLength(2));
    });
  });
}
