import 'dart:convert';

import 'package:dreamfinder/src/agent/tool_registry.dart';
import 'package:dreamfinder/src/db/database.dart';
import 'package:dreamfinder/src/db/queries.dart';
import 'package:dreamfinder/src/tools/chat_config_tools.dart';
import 'package:test/test.dart';

void main() {
  late BotDatabase db;
  late Queries queries;
  late ToolRegistry registry;

  setUp(() {
    db = BotDatabase.inMemory();
    queries = Queries(db);
    registry = ToolRegistry();
    // Set admin context so admin-gated tools pass.
    registry.setContext(const ToolContext(
      senderUuid: 'test-admin',
      isAdmin: true,
      chatId: 'test-chat',
    ));
    registerChatConfigTools(registry, queries);
  });

  tearDown(() {
    db.close();
  });

  // -----------------------------------------------------------------------
  // Workspace linking
  // -----------------------------------------------------------------------

  group('get_chat_config', () {
    test('returns nulls when nothing is configured', () async {
      final result = await registry.executeTool('get_chat_config', {
        'signal_group_id': 'group-1',
      });
      final data = jsonDecode(result) as Map<String, dynamic>;

      expect(data['workspace'], isNull);
      expect(data['default_board'], isNull);
    });

    test('returns workspace and board when configured', () async {
      queries.createWorkspaceLink(
        signalGroupId: 'group-1',
        workspacePublicId: 'ws-abc',
        workspaceName: 'Sprints',
        createdByUuid: 'admin-uuid',
      );
      queries.upsertDefaultBoardConfig(
        signalGroupId: 'group-1',
        boardPublicId: 'board-1',
        boardName: 'Sprint Board',
        listPublicId: 'list-1',
        listName: 'To Do',
      );

      final result = await registry.executeTool('get_chat_config', {
        'signal_group_id': 'group-1',
      });
      final data = jsonDecode(result) as Map<String, dynamic>;

      final ws = data['workspace'] as Map<String, dynamic>;
      expect(ws['workspace_name'], equals('Sprints'));

      final board = data['default_board'] as Map<String, dynamic>;
      expect(board['board_name'], equals('Sprint Board'));
      expect(board['list_name'], equals('To Do'));
    });
  });

  group('link_workspace', () {
    test('links a workspace successfully', () async {
      final result = await registry.executeTool('link_workspace', {
        'signal_group_id': 'group-1',
        'workspace_public_id': 'ws-abc',
        'workspace_name': 'Sprints',
        'created_by_uuid': 'admin-uuid',
      });
      final data = jsonDecode(result) as Map<String, dynamic>;

      expect(data['success'], isTrue);
      expect(data['workspace_name'], equals('Sprints'));

      // Verify persistence.
      final link = queries.getWorkspaceLink('group-1');
      expect(link, isNotNull);
      expect(link!.workspacePublicId, equals('ws-abc'));
    });

    test('rejects duplicate link', () async {
      await registry.executeTool('link_workspace', {
        'signal_group_id': 'group-1',
        'workspace_public_id': 'ws-abc',
        'workspace_name': 'Sprints',
        'created_by_uuid': 'admin-uuid',
      });

      final result = await registry.executeTool('link_workspace', {
        'signal_group_id': 'group-1',
        'workspace_public_id': 'ws-xyz',
        'workspace_name': 'Other',
        'created_by_uuid': 'admin-uuid',
      });
      final data = jsonDecode(result) as Map<String, dynamic>;

      expect(data['success'], isFalse);
      expect(data['error'], contains('already linked'));
    });
  });

  group('unlink_workspace', () {
    test('unlinks successfully', () async {
      queries.createWorkspaceLink(
        signalGroupId: 'group-1',
        workspacePublicId: 'ws-abc',
        workspaceName: 'Sprints',
        createdByUuid: 'admin-uuid',
      );

      final result = await registry.executeTool('unlink_workspace', {
        'signal_group_id': 'group-1',
      });
      final data = jsonDecode(result) as Map<String, dynamic>;

      expect(data['success'], isTrue);
      expect(data['unlinked_workspace'], equals('Sprints'));
      expect(queries.getWorkspaceLink('group-1'), isNull);
    });

    test('returns error when no link exists', () async {
      final result = await registry.executeTool('unlink_workspace', {
        'signal_group_id': 'group-1',
      });
      final data = jsonDecode(result) as Map<String, dynamic>;

      expect(data['success'], isFalse);
      expect(data['error'], contains('not linked'));
    });
  });

  group('set_default_board', () {
    test('sets default board config', () async {
      final result = await registry.executeTool('set_default_board', {
        'signal_group_id': 'group-1',
        'board_public_id': 'board-1',
        'board_name': 'Sprint Board',
        'list_public_id': 'list-1',
        'list_name': 'To Do',
      });
      final data = jsonDecode(result) as Map<String, dynamic>;

      expect(data['success'], isTrue);
      expect(data['board_name'], equals('Sprint Board'));

      final config = queries.getDefaultBoardConfig('group-1');
      expect(config!.listName, equals('To Do'));
    });

    test('updates existing config', () async {
      await registry.executeTool('set_default_board', {
        'signal_group_id': 'group-1',
        'board_public_id': 'board-1',
        'board_name': 'Old Board',
        'list_public_id': 'list-1',
        'list_name': 'Old List',
      });

      await registry.executeTool('set_default_board', {
        'signal_group_id': 'group-1',
        'board_public_id': 'board-2',
        'board_name': 'New Board',
        'list_public_id': 'list-2',
        'list_name': 'New List',
      });

      final config = queries.getDefaultBoardConfig('group-1');
      expect(config!.boardName, equals('New Board'));
    });
  });

  // -----------------------------------------------------------------------
  // User Mapping
  // -----------------------------------------------------------------------

  group('get_user_mapping', () {
    test('returns found=false when no mapping exists', () async {
      final result = await registry.executeTool('get_user_mapping', {
        'signal_uuid': 'uuid-1',
      });
      final data = jsonDecode(result) as Map<String, dynamic>;

      expect(data['found'], isFalse);
    });

    test('returns mapping when it exists', () async {
      queries.createUserLink(
        signalUuid: 'uuid-1',
        kanUserEmail: 'alice@example.com',
        signalDisplayName: 'Alice',
      );

      final result = await registry.executeTool('get_user_mapping', {
        'signal_uuid': 'uuid-1',
      });
      final data = jsonDecode(result) as Map<String, dynamic>;

      expect(data['found'], isTrue);
      expect(data['kan_user_email'], equals('alice@example.com'));
      expect(data['signal_display_name'], equals('Alice'));
    });
  });

  group('create_user_mapping', () {
    test('creates a mapping successfully', () async {
      final result = await registry.executeTool('create_user_mapping', {
        'signal_uuid': 'uuid-1',
        'kan_user_email': 'alice@example.com',
        'signal_display_name': 'Alice',
      });
      final data = jsonDecode(result) as Map<String, dynamic>;

      expect(data['success'], isTrue);
      expect(data['kan_user_email'], equals('alice@example.com'));
    });

    test('rejects duplicate mapping', () async {
      queries.createUserLink(
        signalUuid: 'uuid-1',
        kanUserEmail: 'alice@example.com',
      );

      final result = await registry.executeTool('create_user_mapping', {
        'signal_uuid': 'uuid-1',
        'kan_user_email': 'other@example.com',
      });
      final data = jsonDecode(result) as Map<String, dynamic>;

      expect(data['success'], isFalse);
      expect(data['error'], contains('already mapped'));
    });
  });

  group('remove_user_mapping', () {
    test('removes an existing mapping', () async {
      queries.createUserLink(
        signalUuid: 'uuid-1',
        kanUserEmail: 'alice@example.com',
      );

      final result = await registry.executeTool('remove_user_mapping', {
        'signal_uuid': 'uuid-1',
      });
      final data = jsonDecode(result) as Map<String, dynamic>;

      expect(data['success'], isTrue);
      expect(data['removed_email'], equals('alice@example.com'));
      expect(queries.getUserLink('uuid-1'), isNull);
    });

    test('returns error when no mapping exists', () async {
      final result = await registry.executeTool('remove_user_mapping', {
        'signal_uuid': 'uuid-1',
      });
      final data = jsonDecode(result) as Map<String, dynamic>;

      expect(data['success'], isFalse);
      expect(data['error'], contains('No mapping found'));
    });
  });

  group('list_user_mappings', () {
    test('returns empty list when none exist', () async {
      final result = await registry.executeTool('list_user_mappings', {});
      final data = jsonDecode(result) as Map<String, dynamic>;

      expect(data['count'], equals(0));
      expect(data['mappings'], isEmpty);
    });

    test('returns all mappings', () async {
      queries.createUserLink(
        signalUuid: 'uuid-1',
        kanUserEmail: 'alice@example.com',
        signalDisplayName: 'Alice',
      );
      queries.createUserLink(
        signalUuid: 'uuid-2',
        kanUserEmail: 'bob@example.com',
        signalDisplayName: 'Bob',
      );

      final result = await registry.executeTool('list_user_mappings', {});
      final data = jsonDecode(result) as Map<String, dynamic>;

      expect(data['count'], equals(2));
      final mappings = data['mappings'] as List<dynamic>;
      final emails = mappings
          .map((m) => (m as Map<String, dynamic>)['kan_user_email'])
          .toList();
      expect(emails, containsAll(['alice@example.com', 'bob@example.com']));
    });
  });

  // -----------------------------------------------------------------------
  // Admin enforcement
  // -----------------------------------------------------------------------

  group('admin enforcement', () {
    test('rejects non-admin callers for admin-gated tools', () async {
      registry.setContext(const ToolContext(
        senderUuid: 'non-admin-user',
        isAdmin: false,
        chatId: 'test-chat',
      ));

      // All write operations should be rejected.
      for (final toolName in [
        'link_workspace',
        'unlink_workspace',
        'set_default_board',
        'create_user_mapping',
        'remove_user_mapping',
      ]) {
        final result = await registry.executeTool(toolName, {
          'signal_group_id': 'g1',
          'workspace_public_id': 'ws1',
          'workspace_name': 'Test',
          'created_by_uuid': 'admin',
          'board_public_id': 'b1',
          'board_name': 'Board',
          'list_public_id': 'l1',
          'list_name': 'List',
          'signal_uuid': 'u1',
          'kan_user_email': 'x@x.com',
        });
        final data = jsonDecode(result) as Map<String, dynamic>;
        expect(data['error'], contains('admin'),
            reason: '$toolName should require admin');
      }
    });

    test('allows non-admin callers for read-only tools', () async {
      registry.setContext(const ToolContext(
        senderUuid: 'regular-user',
        isAdmin: false,
        chatId: 'test-chat',
      ));

      // Read operations should succeed.
      for (final entry in <String, Map<String, dynamic>>{
        'get_chat_config': {'signal_group_id': 'g1'},
        'get_user_mapping': {'signal_uuid': 'u1'},
        'list_user_mappings': {},
      }.entries) {
        final result = await registry.executeTool(entry.key, entry.value);
        final data = jsonDecode(result) as Map<String, dynamic>;
        expect(data.containsKey('error'), isFalse,
            reason: '${entry.key} should not require admin');
      }
    });
  });
}
