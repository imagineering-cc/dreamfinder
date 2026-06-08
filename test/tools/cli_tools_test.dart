import 'dart:convert';

import 'package:dreamfinder/src/agent/tool_registry.dart';
import 'package:dreamfinder/src/tools/cli_tools.dart';
import 'package:test/test.dart';

/// These tests exercise the `run_cli` executor's validation and per-subcommand
/// admin gating — the paths that fail-fast BEFORE spawning the node CLI, so no
/// network or node runtime is required. The happy-path subprocess behaviour is
/// covered by live smoke tests, not here.
void main() {
  ToolRegistry makeRegistry({required bool isAdmin}) {
    final registry = ToolRegistry();
    registry.setContext(ToolContext(
      senderId: 'u1',
      isAdmin: isAdmin,
      chatId: 'c1',
    ));
    registerCliTools(
      registry,
      kanApiKey: 'k',
      kanBaseUrl: 'https://kan.example/api/v1',
      outlineApiKey: 'o',
      outlineBaseUrl: 'https://outline.example/api',
    );
    return registry;
  }

  Future<Map<String, dynamic>> run(
    ToolRegistry registry,
    Map<String, dynamic> args,
  ) async {
    final raw = await registry.executeTool('run_cli', args);
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  test('exposes a single run_cli tool', () {
    final registry = makeRegistry(isAdmin: false);
    final names = registry.getAllToolDefinitions().map((t) => t.name).toList();
    expect(names, contains('run_cli'));
    expect(names.where((n) => n == 'run_cli'), hasLength(1));
  });

  test('rejects unknown tool', () async {
    final result = await run(makeRegistry(isAdmin: true), {
      'tool': 'rm',
      'args': ['-rf', '/'],
    });
    expect(result['error'], contains('Unknown tool'));
  });

  test('rejects empty args array', () async {
    final result = await run(makeRegistry(isAdmin: true), {
      'tool': 'kan',
      'args': <String>[],
    });
    expect(result['error'], contains('non-empty array'));
  });

  group('admin gating', () {
    test('blocks destructive kan subcommand for non-admin', () async {
      final result = await run(makeRegistry(isAdmin: false), {
        'tool': 'kan',
        'args': ['delete-board', '--board-id', 'abc123def456'],
      });
      expect(result['error'], contains('admin'));
      expect(result['subcommand'], 'delete-board');
    });

    test('blocks invite-link rotation for non-admin', () async {
      final result = await run(makeRegistry(isAdmin: false), {
        'tool': 'kan',
        'args': ['create-invite-link', '--workspace-id', 'abc123def456'],
      });
      expect(result['error'], contains('admin'));
    });

    test('blocks outline collection mutation for non-admin', () async {
      final result = await run(makeRegistry(isAdmin: false), {
        'tool': 'outline',
        'args': ['collections.delete', '--id', 'xyz'],
      });
      expect(result['error'], contains('admin'));
    });

    test('gates permanent document delete but not trash delete', () async {
      final permanent = await run(makeRegistry(isAdmin: false), {
        'tool': 'outline',
        'args': ['documents.delete', '--id', 'xyz', '--permanent'],
      });
      expect(permanent['error'], contains('admin'),
          reason: 'permanent delete bypasses trash — admin only');

      // Trash delete for a non-admin must NOT be admin-blocked. It will fail
      // when the CLI runs (fake creds), but the error must not be the admin
      // refusal — proving the gate let it through.
      final trash = await run(makeRegistry(isAdmin: false), {
        'tool': 'outline',
        'args': ['documents.delete', '--id', 'xyz'],
      });
      final err = (trash['error'] ?? '').toString();
      expect(err.contains('admin privileges'), isFalse,
          reason: 'members may delete docs to trash');
    });
  });
}
