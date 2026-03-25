import 'dart:convert';
import 'dart:io';

import 'package:dreamfinder/src/mcp/mcp_config.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('mcp_config_test_');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  String writeTempConfig(List<Map<String, dynamic>> servers) {
    final path = '${tempDir.path}/mcp-config.json';
    File(path).writeAsStringSync(jsonEncode(servers));
    return path;
  }

  group('loadMcpConfig', () {
    test('returns empty list when file does not exist', () {
      final configs = loadMcpConfig('${tempDir.path}/nonexistent.json');
      expect(configs, isEmpty);
    });

    test('parses a basic server config', () {
      final path = writeTempConfig([
        {
          'name': 'test-server',
          'command': 'node',
          'args': ['server.js'],
          'env': {},
        },
      ]);

      final configs = loadMcpConfig(path);
      expect(configs, hasLength(1));
      expect(configs.first.name, 'test-server');
      expect(configs.first.command, 'node');
      expect(configs.first.args, ['server.js']);
      expect(configs.first.env, isEmpty);
    });

    test('skips disabled servers', () {
      final path = writeTempConfig([
        {
          'name': 'enabled',
          'command': 'node',
          'args': ['a.js'],
          'env': {},
        },
        {
          'name': 'disabled',
          'command': 'node',
          'args': ['b.js'],
          'env': {},
          'enabled': false,
        },
      ]);

      final configs = loadMcpConfig(path);
      expect(configs, hasLength(1));
      expect(configs.first.name, 'enabled');
    });

    test('resolves environment variable references', () {
      // Set a test env var via the process — we can only test with vars
      // that are actually in the environment. PATH is always set.
      final path = writeTempConfig([
        {
          'name': 'test',
          'command': 'node',
          'args': ['server.js'],
          'env': {
            'MY_PATH': r'$PATH',
          },
        },
      ]);

      final configs = loadMcpConfig(path);
      expect(configs, hasLength(1));
      expect(configs.first.env['MY_PATH'], isNotEmpty);
      expect(configs.first.env['MY_PATH'], isNot(contains(r'$')));
    });

    test('resolves braced env var syntax', () {
      final path = writeTempConfig([
        {
          'name': 'test',
          'command': 'node',
          'args': ['server.js'],
          'env': {
            'MY_PATH': r'${PATH}',
          },
        },
      ]);

      final configs = loadMcpConfig(path);
      expect(configs, hasLength(1));
      expect(configs.first.env['MY_PATH'], isNotEmpty);
    });

    test('skips server when env var is unset', () {
      final path = writeTempConfig([
        {
          'name': 'needs-secret',
          'command': 'node',
          'args': ['server.js'],
          'env': {
            'SECRET': r'$DEFINITELY_NOT_A_REAL_ENV_VAR_12345',
          },
        },
      ]);

      final configs = loadMcpConfig(path);
      expect(configs, isEmpty);
    });

    test('passes through literal env values', () {
      final path = writeTempConfig([
        {
          'name': 'literal',
          'command': 'node',
          'args': ['server.js'],
          'env': {
            'API_URL': 'https://api.example.com',
          },
        },
      ]);

      final configs = loadMcpConfig(path);
      expect(configs, hasLength(1));
      expect(configs.first.env['API_URL'], 'https://api.example.com');
    });

    test('handles multiple servers', () {
      final path = writeTempConfig([
        {
          'name': 'server-a',
          'command': 'node',
          'args': ['a.js'],
          'env': {},
        },
        {
          'name': 'server-b',
          'command': 'python',
          'args': ['b.py', '--port', '8080'],
          'env': {},
        },
      ]);

      final configs = loadMcpConfig(path);
      expect(configs, hasLength(2));
      expect(configs[0].name, 'server-a');
      expect(configs[1].name, 'server-b');
      expect(configs[1].command, 'python');
      expect(configs[1].args, ['b.py', '--port', '8080']);
    });

    test('defaults enabled to true when not specified', () {
      final path = writeTempConfig([
        {
          'name': 'no-enabled-field',
          'command': 'node',
          'args': ['server.js'],
          'env': {},
        },
      ]);

      final configs = loadMcpConfig(path);
      expect(configs, hasLength(1));
    });

    test('handles missing env key gracefully', () {
      final path = writeTempConfig([
        {
          'name': 'no-env',
          'command': 'node',
          'args': ['server.js'],
        },
      ]);

      final configs = loadMcpConfig(path);
      expect(configs, hasLength(1));
      expect(configs.first.env, isEmpty);
    });
  });
}
