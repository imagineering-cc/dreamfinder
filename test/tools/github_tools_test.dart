import 'dart:convert';

import 'package:dreamfinder/src/agent/tool_registry.dart';
import 'package:dreamfinder/src/tools/github_tools.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

void main() {
  late ToolRegistry registry;

  /// Creates a mock HTTP client that returns [body] with [statusCode].
  http.Client mockClient(
    String body, {
    int statusCode = 200,
    void Function(http.BaseRequest)? onRequest,
  }) {
    return http_testing.MockClient((request) async {
      onRequest?.call(request);
      return http.Response(body, statusCode);
    });
  }

  setUp(() {
    registry = ToolRegistry();
  });

  group('registerGitHubTools', () {
    test('does not register tools when token is null', () {
      registerGitHubTools(registry, token: null);
      final tools = registry.getAllToolDefinitions();
      final githubTools = tools
          .where((ToolDefinition t) =>
              t.name.contains('repo') || t.name.contains('github'))
          .toList();
      expect(githubTools, isEmpty);
    });

    test('does not register tools when token is empty', () {
      registerGitHubTools(registry, token: '');
      final tools = registry.getAllToolDefinitions();
      final githubTools = tools
          .where((ToolDefinition t) =>
              t.name.contains('repo') || t.name.contains('github'))
          .toList();
      expect(githubTools, isEmpty);
    });

    test('registers all five tools when token is provided', () {
      registerGitHubTools(registry, token: 'test-token');
      final tools = registry.getAllToolDefinitions();
      final names = tools.map((ToolDefinition t) => t.name).toSet();
      expect(names, contains('read_repo_file'));
      expect(names, contains('list_repo_files'));
      expect(names, contains('search_repo_code'));
      expect(names, contains('create_github_issue'));
      expect(names, contains('list_github_issues'));
    });
  });

  group('read_repo_file', () {
    test('returns file content decoded from base64', () async {
      final content = base64Encode(utf8.encode('void main() {}'));
      final responseBody = jsonEncode({
        'type': 'file',
        'content': content,
        'size': 14,
        'encoding': 'base64',
      });

      registerGitHubTools(
        registry,
        token: 'test-token',
        httpClient: mockClient(responseBody),
      );

      final result = await registry.executeTool(
        'read_repo_file',
        {'path': 'bin/main.dart'},
      );
      expect(result, 'void main() {}');
    });

    test('returns error for 404', () async {
      registerGitHubTools(
        registry,
        token: 'test-token',
        httpClient: mockClient('', statusCode: 404),
      );

      final result = await registry.executeTool(
        'read_repo_file',
        {'path': 'nonexistent.dart'},
      );
      expect(result, contains('File not found'));
    });

    test('detects directories', () async {
      registerGitHubTools(
        registry,
        token: 'test-token',
        httpClient: mockClient(jsonEncode([
          {'name': 'foo.dart', 'type': 'file', 'size': 100},
        ])),
      );

      final result = await registry.executeTool(
        'read_repo_file',
        {'path': 'lib/src'},
      );
      expect(result, contains('directory'));
      expect(result, contains('list_repo_files'));
    });

    test('truncates large files', () async {
      final bigContent = 'x' * 150000;
      final encoded = base64Encode(utf8.encode(bigContent));
      final responseBody = jsonEncode({
        'type': 'file',
        'content': encoded,
        'size': 150000,
        'encoding': 'base64',
      });

      registerGitHubTools(
        registry,
        token: 'test-token',
        httpClient: mockClient(responseBody),
      );

      final result = await registry.executeTool(
        'read_repo_file',
        {'path': 'big.txt'},
      );
      expect(result, contains('[truncated'));
      expect(result.length, lessThan(150000));
    });

    test('sends auth header', () async {
      String? authHeader;
      final content = base64Encode(utf8.encode('hello'));
      final responseBody = jsonEncode({
        'type': 'file',
        'content': content,
        'size': 5,
      });

      registerGitHubTools(
        registry,
        token: 'my-secret-token',
        httpClient: mockClient(responseBody, onRequest: (req) {
          authHeader = req.headers['Authorization'];
        }),
      );

      await registry.executeTool('read_repo_file', {'path': 'test.txt'});
      expect(authHeader, 'Bearer my-secret-token');
    });
  });

  group('list_repo_files', () {
    test('returns formatted directory listing', () async {
      final responseBody = jsonEncode([
        {'name': 'lib', 'type': 'dir', 'size': 0, 'path': 'lib'},
        {'name': 'pubspec.yaml', 'type': 'file', 'size': 1024, 'path': 'pubspec.yaml'},
        {'name': 'README.md', 'type': 'file', 'size': 512, 'path': 'README.md'},
      ]);

      registerGitHubTools(
        registry,
        token: 'test-token',
        httpClient: mockClient(responseBody),
      );

      final result = await registry.executeTool('list_repo_files', {});
      expect(result, contains('3 items'));
      expect(result, contains('📁 lib'));
      expect(result, contains('📄 pubspec.yaml'));
      expect(result, contains('1.0 KB'));
    });

    test('returns error for nonexistent path', () async {
      registerGitHubTools(
        registry,
        token: 'test-token',
        httpClient: mockClient('', statusCode: 404),
      );

      final result = await registry.executeTool(
        'list_repo_files',
        {'path': 'nonexistent'},
      );
      expect(result, contains('Path not found'));
    });
  });

  group('search_repo_code', () {
    test('returns matching files', () async {
      final responseBody = jsonEncode({
        'total_count': 2,
        'items': [
          {'path': 'lib/src/foo.dart', 'name': 'foo.dart'},
          {'path': 'lib/src/bar.dart', 'name': 'bar.dart'},
        ],
      });

      registerGitHubTools(
        registry,
        token: 'test-token',
        httpClient: mockClient(responseBody),
      );

      final result = await registry.executeTool(
        'search_repo_code',
        {'query': 'class Foo'},
      );
      expect(result, contains('2 result(s)'));
      expect(result, contains('lib/src/foo.dart'));
      expect(result, contains('lib/src/bar.dart'));
    });

    test('returns message when no results', () async {
      final responseBody = jsonEncode({
        'total_count': 0,
        'items': <dynamic>[],
      });

      registerGitHubTools(
        registry,
        token: 'test-token',
        httpClient: mockClient(responseBody),
      );

      final result = await registry.executeTool(
        'search_repo_code',
        {'query': 'nonexistent_symbol'},
      );
      expect(result, contains('No results found'));
    });
  });

  group('create_github_issue', () {
    test('creates issue and returns number and URL', () async {
      final responseBody = jsonEncode({
        'number': 42,
        'html_url': 'https://github.com/test/repo/issues/42',
        'title': 'Test issue',
      });

      registerGitHubTools(
        registry,
        token: 'test-token',
        httpClient: mockClient(responseBody, statusCode: 201),
      );

      final result = await registry.executeTool(
        'create_github_issue',
        {'title': 'Test issue'},
      );
      final parsed = jsonDecode(result) as Map<String, dynamic>;
      expect(parsed['success'], isTrue);
      expect(parsed['number'], 42);
      expect(parsed['url'], contains('issues/42'));
    });

    test('returns error on failure', () async {
      registerGitHubTools(
        registry,
        token: 'test-token',
        httpClient: mockClient('Unauthorized', statusCode: 401),
      );

      final result = await registry.executeTool(
        'create_github_issue',
        {'title': 'Test'},
      );
      expect(result, contains('Failed to create issue'));
      expect(result, contains('401'));
    });
  });

  group('list_github_issues', () {
    test('returns formatted issue list', () async {
      final responseBody = jsonEncode([
        {
          'number': 1,
          'title': 'Bug report',
          'state': 'open',
          'html_url': 'https://github.com/test/repo/issues/1',
          'labels': [
            {'name': 'bug'},
          ],
          'assignees': <dynamic>[],
          'updated_at': '2026-03-14T00:00:00Z',
        },
      ]);

      registerGitHubTools(
        registry,
        token: 'test-token',
        httpClient: mockClient(responseBody),
      );

      final result = await registry.executeTool('list_github_issues', {});
      expect(result, contains('#1: Bug report'));
      expect(result, contains('Labels: bug'));
      expect(result, contains('1 issue(s)'));
    });

    test('filters out pull requests', () async {
      final responseBody = jsonEncode([
        {
          'number': 1,
          'title': 'A PR',
          'state': 'open',
          'html_url': 'https://github.com/test/repo/pull/1',
          'labels': <dynamic>[],
          'assignees': <dynamic>[],
          'updated_at': '2026-03-14T00:00:00Z',
          'pull_request': {'url': 'some-url'},
        },
      ]);

      registerGitHubTools(
        registry,
        token: 'test-token',
        httpClient: mockClient(responseBody),
      );

      final result = await registry.executeTool('list_github_issues', {});
      expect(result, contains('No open issues found'));
    });
  });
}
