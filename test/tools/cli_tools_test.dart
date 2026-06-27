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
      radicaleBaseUrl: 'https://dav.example.com',
      radicaleUsername: 'nick',
      radicalePassword: 'secret',
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

  group('forbidden flags (any sender)', () {
    test('rejects --text-file (arbitrary file read) even for admin', () async {
      final result = await run(makeRegistry(isAdmin: true), {
        'tool': 'outline',
        'args': [
          'documents.create',
          '--title',
          'x',
          '--text-file',
          '/app/.env'
        ],
      });
      expect(result['error'], contains('--text-file'));
    });

    test('rejects --text-file=PATH form', () async {
      final result = await run(makeRegistry(isAdmin: true), {
        'tool': 'outline',
        'args': ['documents.create', '--text-file=/proc/self/environ'],
      });
      expect(result['error'], contains('--text-file'));
    });

    test('rejects --site credential selection', () async {
      final result = await run(makeRegistry(isAdmin: true), {
        'tool': 'kan',
        'args': ['--site', 'xdeca', 'list-workspaces'],
      });
      expect(result['error'], contains('--site'));
    });
  });

  group('args type contract', () {
    test('rejects non-string args elements', () async {
      final result = await run(makeRegistry(isAdmin: true), {
        'tool': 'kan',
        'args': [
          'create-card',
          {'nested': 'object'},
        ],
      });
      expect(result['error'], contains('must be a string'));
    });
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

    test('blocks outline raw escape hatch for non-admin', () async {
      // The headline cage-match finding: raw could call any verb, bypassing
      // the per-subcommand gate. It must itself be admin-gated.
      final result = await run(makeRegistry(isAdmin: false), {
        'tool': 'outline',
        'args': ['raw', '--verb', 'collections.delete', '--body', '{"id":"x"}'],
      });
      expect(result['error'], contains('admin'));
    });

    test('blocks create-board (structural) for non-admin', () async {
      final result = await run(makeRegistry(isAdmin: false), {
        'tool': 'kan',
        'args': [
          'create-board',
          '--workspace-id',
          'abc123def456',
          '--name',
          'B'
        ],
      });
      expect(result['error'], contains('admin'));
    });

    test('blocks admin-role invite for non-admin but allows member invite',
        () async {
      final escalate = await run(makeRegistry(isAdmin: false), {
        'tool': 'outline',
        'args': [
          'users.invite',
          '--email',
          'x@y.com',
          '--name',
          'X',
          '--role',
          'admin'
        ],
      });
      expect(escalate['error'], contains('admin'),
          reason: 'minting an admin requires admin');

      // A plain member invite must NOT be admin-blocked (self-service
      // onboarding). It will fail when the CLI runs (fake creds), but the
      // error must not be the admin refusal.
      final member = await run(makeRegistry(isAdmin: false), {
        'tool': 'outline',
        'args': ['users.invite', '--email', 'x@y.com', '--name', 'X'],
      });
      expect((member['error'] ?? '').toString().contains('admin privileges'),
          isFalse,
          reason: 'inviting a member is open for onboarding');
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

    test('blocks radicale calendar write subcommands for non-admin', () async {
      for (final sub in ['add-event', 'delete-event', 'mkcalendar']) {
        final result = await run(makeRegistry(isAdmin: false), {
          'tool': 'radicale',
          'args': [sub, '--calendar', 'nick/imagineering-events'],
        });
        expect(result['error'], contains('admin'),
            reason: '$sub writes the shared calendar — admin only');
        expect(result['subcommand'], sub);
      }
    });

    test('blocks radicale contact write subcommands for non-admin', () async {
      for (final sub in [
        'mkaddressbook',
        'add-contact',
        'update-contact',
        'delete-contact'
      ]) {
        final result = await run(makeRegistry(isAdmin: false), {
          'tool': 'radicale',
          'args': [sub, '--addressbook', 'dreamfinder/team-profiles'],
        });
        expect(result['error'], contains('admin'),
            reason: '$sub writes the shared address book — admin only');
        expect(result['subcommand'], sub);
      }
    });

    test('gates cross-principal --user enumeration for non-admin', () async {
      // Listing your OWN collections (no --user, or --user == the configured
      // principal 'nick') is open; naming ANOTHER principal reaches through
      // River's shared creds into their collections and is admin-only
      // (Carnot, cage-match PR #115 r4).
      for (final sub in ['list-calendars', 'list-address-books']) {
        final blocked = await run(makeRegistry(isAdmin: false), {
          'tool': 'radicale',
          'args': [sub, '--user', 'someone-else'],
        });
        expect(blocked['error'], contains('admin'),
            reason: '$sub --user <other> enumerates another principal');
        expect(blocked['subcommand'], sub);

        for (final args in [
          [sub],
          [sub, '--user', 'nick'],
        ]) {
          final allowed = await run(makeRegistry(isAdmin: false), {
            'tool': 'radicale',
            'args': args,
          });
          expect(
              (allowed['error'] ?? '').toString().contains('admin privileges'),
              isFalse,
              reason: '$args lists your own collections — open');
        }
      }
    });

    test('allows cross-principal --user enumeration for admin', () async {
      for (final sub in ['list-calendars', 'list-address-books']) {
        final result = await run(makeRegistry(isAdmin: true), {
          'tool': 'radicale',
          'args': [sub, '--user', 'someone-else'],
        });
        expect(
            (result['error'] ?? '').toString().contains('admin privileges'),
            isFalse,
            reason: 'admins may enumerate any principal');
      }
    });

    test('allows radicale calendar reads for non-admin (read is open)',
        () async {
      // Passes the admin gate, then fails when the node CLI runs against fake
      // creds — but the error must NOT be the admin refusal, proving the gate
      // let the read through.
      for (final args in [
        ['list-calendars'],
        ['list-events', '--calendar', 'nick/imagineering-events'],
        ['get-event', '--calendar', 'nick/imagineering-events', '--uid', 'x'],
      ]) {
        final result = await run(makeRegistry(isAdmin: false), {
          'tool': 'radicale',
          'args': args,
        });
        final err = (result['error'] ?? '').toString();
        expect(err.contains('admin privileges'), isFalse,
            reason: '${args.first} is open to all members');
      }
    });

    test('allows radicale contact reads for non-admin (read is open)',
        () async {
      for (final args in [
        ['list-address-books'],
        ['list-contacts', '--addressbook', 'dreamfinder/team-profiles'],
        [
          'get-contact',
          '--addressbook',
          'dreamfinder/team-profiles',
          '--uid',
          'x'
        ],
      ]) {
        final result = await run(makeRegistry(isAdmin: false), {
          'tool': 'radicale',
          'args': args,
        });
        final err = (result['error'] ?? '').toString();
        expect(err.contains('admin privileges'), isFalse,
            reason: '${args.first} is open to all members');
      }
    });

    test('allows radicale write subcommands for admin', () async {
      // Admin clears the gate; the call then fails at the node CLI (fake creds),
      // but the error must NOT be the admin refusal.
      for (final args in [
        ['mkcalendar', '--calendar', 'nick/new-cal'],
        [
          'add-contact',
          '--addressbook',
          'dreamfinder/team-profiles',
          '--fn',
          'Ada'
        ],
      ]) {
        final result = await run(makeRegistry(isAdmin: true), {
          'tool': 'radicale',
          'args': args,
        });
        final err = (result['error'] ?? '').toString();
        expect(err.contains('admin privileges'), isFalse,
            reason: 'admins may write the shared calendar / contacts');
      }
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
