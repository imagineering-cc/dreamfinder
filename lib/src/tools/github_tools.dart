/// Custom tools for reading GitHub repository contents and managing issues.
///
/// Gives the agent the ability to read its own source code, browse the
/// codebase structure, and file/list GitHub issues — all via the GitHub
/// REST API with a fine-grained PAT.
///
/// - `read_repo_file`: Read any file from a GitHub repository.
/// - `list_repo_files`: Browse directory contents.
/// - `search_repo_code`: Search code in a repository.
/// - `create_github_issue`: File a new issue.
/// - `list_github_issues`: List open/closed issues.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../agent/tool_registry.dart';

/// Maximum file content returned to the agent (~100 KB).
const _maxFileSize = 100000;

/// Registers GitHub repository tools with the [ToolRegistry].
///
/// If [token] is null, the tools are not registered (silently disabled).
/// The [defaultRepo] and [defaultBranch] provide defaults so the agent
/// doesn't need to specify them for every call.
void registerGitHubTools(
  ToolRegistry registry, {
  required String? token,
  String defaultRepo = 'imagineering-cc/dreamfinder',
  String defaultBranch = 'main',
  http.Client? httpClient,
}) {
  if (token == null || token.isEmpty) return;

  final client = httpClient ?? http.Client();

  registry.registerCustomTool(
    _readRepoFileTool(token, defaultRepo, defaultBranch, client),
  );
  registry.registerCustomTool(
    _listRepoFilesTool(token, defaultRepo, defaultBranch, client),
  );
  registry.registerCustomTool(
    _searchRepoCodeTool(token, defaultRepo, defaultBranch, client),
  );
  registry.registerCustomTool(
    _createGitHubIssueTool(token, defaultRepo, client),
  );
  registry.registerCustomTool(
    _listGitHubIssuesTool(token, defaultRepo, client),
  );
}

/// Makes an authenticated GitHub API request.
Future<http.Response> _ghFetch(
  http.Client client,
  String token,
  String path, {
  String method = 'GET',
  Map<String, dynamic>? body,
}) async {
  final uri = Uri.parse('https://api.github.com$path');
  final headers = <String, String>{
    'Accept': 'application/vnd.github.v3+json',
    'Authorization': 'Bearer $token',
    'User-Agent': 'dreamfinder-bot',
  };

  if (method == 'GET') {
    return client.get(uri, headers: headers);
  } else {
    headers['Content-Type'] = 'application/json';
    return client.post(uri, headers: headers, body: jsonEncode(body));
  }
}

/// Formats bytes to human-readable size.
String _formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

CustomToolDef _readRepoFileTool(
  String token,
  String defaultRepo,
  String defaultBranch,
  http.Client client,
) {
  return CustomToolDef(
    name: 'read_repo_file',
    description: 'Read a file from a GitHub repository. Returns the file '
        'content as text. Use this to read source code, config files, docs, '
        'etc. Defaults to the Dreamfinder repo on the main branch.',
    inputSchema: <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'path': <String, dynamic>{
          'type': 'string',
          'description':
              "File path relative to repo root (e.g. 'lib/src/agent/agent_loop.dart')",
        },
        'repo': <String, dynamic>{
          'type': 'string',
          'description':
              'Repository in owner/name format (default: $defaultRepo)',
        },
        'ref': <String, dynamic>{
          'type': 'string',
          'description':
              'Branch, tag, or commit SHA (default: $defaultBranch)',
        },
      },
      'required': <String>['path'],
    },
    handler: (args) async {
      final path = (args['path'] as String).replaceFirst(RegExp(r'^/'), '');
      final repo = args['repo'] as String? ?? defaultRepo;
      final ref = args['ref'] as String? ?? defaultBranch;

      final res = await _ghFetch(
        client,
        token,
        '/repos/$repo/contents/${Uri.encodeComponent(path)}?ref=$ref',
      );

      if (res.statusCode == 404) {
        return 'File not found: $path (repo: $repo, ref: $ref)';
      }
      if (res.statusCode != 200) {
        return 'GitHub API error: ${res.statusCode} ${res.reasonPhrase}';
      }

      final data = jsonDecode(res.body);

      if (data is List) {
        return '"$path" is a directory, not a file. Use list_repo_files instead.';
      }

      final map = data as Map<String, dynamic>;
      if (map['type'] != 'file') {
        return '"$path" is a ${map['type']}, not a file.';
      }

      final contentBase64 = map['content'] as String?;
      if (contentBase64 == null) {
        return 'File "$path" is too large for the Contents API '
            '(${map['size']} bytes). Try a smaller file.';
      }

      final content = utf8.decode(base64Decode(contentBase64.replaceAll('\n', '')));
      if (content.length > _maxFileSize) {
        return '${content.substring(0, _maxFileSize)}\n\n'
            '[truncated — file is ${map['size']} bytes, '
            'showing first $_maxFileSize]';
      }
      return content;
    },
  );
}

CustomToolDef _listRepoFilesTool(
  String token,
  String defaultRepo,
  String defaultBranch,
  http.Client client,
) {
  return CustomToolDef(
    name: 'list_repo_files',
    description: 'List files and directories in a GitHub repository path. '
        'Returns names, types (file/dir), and sizes. '
        'Use this to explore the codebase structure before reading files.',
    inputSchema: <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'path': <String, dynamic>{
          'type': 'string',
          'description':
              "Directory path relative to repo root (e.g. 'lib/src/tools'). "
                  "Empty or '/' for root.",
        },
        'repo': <String, dynamic>{
          'type': 'string',
          'description':
              'Repository in owner/name format (default: $defaultRepo)',
        },
        'ref': <String, dynamic>{
          'type': 'string',
          'description':
              'Branch, tag, or commit SHA (default: $defaultBranch)',
        },
      },
    },
    handler: (args) async {
      final path = (args['path'] as String? ?? '').replaceFirst(RegExp(r'^/'), '');
      final repo = args['repo'] as String? ?? defaultRepo;
      final ref = args['ref'] as String? ?? defaultBranch;

      final apiPath = path.isNotEmpty
          ? '/repos/$repo/contents/${Uri.encodeComponent(path)}?ref=$ref'
          : '/repos/$repo/contents?ref=$ref';

      final res = await _ghFetch(client, token, apiPath);

      if (res.statusCode == 404) {
        return 'Path not found: ${path.isEmpty ? "/" : path} '
            '(repo: $repo, ref: $ref)';
      }
      if (res.statusCode != 200) {
        return 'GitHub API error: ${res.statusCode} ${res.reasonPhrase}';
      }

      final data = jsonDecode(res.body);

      if (data is! List) {
        return '"$path" is a file, not a directory. Use read_repo_file instead.';
      }

      final items = data.cast<Map<String, dynamic>>();
      final lines = items.map((item) {
        final type = item['type'] as String;
        final name = item['name'] as String;
        final size = type == 'file' ? ' (${_formatSize(item['size'] as int)})' : '';
        final icon = type == 'dir' ? '📁' : '📄';
        return '$icon $name$size';
      });

      return '${path.isEmpty ? "/" : path} (${items.length} items):\n'
          '${lines.join("\n")}';
    },
  );
}

CustomToolDef _searchRepoCodeTool(
  String token,
  String defaultRepo,
  String defaultBranch,
  http.Client client,
) {
  return CustomToolDef(
    name: 'search_repo_code',
    description: 'Search for code in a GitHub repository using GitHub code '
        'search. Returns matching file paths and code snippets. '
        'Useful for finding where something is defined or used.',
    inputSchema: <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'query': <String, dynamic>{
          'type': 'string',
          'description':
              'Search query (e.g. "registerGitHubTools", "class AgentLoop")',
        },
        'repo': <String, dynamic>{
          'type': 'string',
          'description':
              'Repository in owner/name format (default: $defaultRepo)',
        },
      },
      'required': <String>['query'],
    },
    handler: (args) async {
      final query = args['query'] as String;
      final repo = args['repo'] as String? ?? defaultRepo;

      final searchQuery = Uri.encodeQueryComponent('$query repo:$repo');
      final res = await _ghFetch(
        client,
        token,
        '/search/code?q=$searchQuery&per_page=10',
      );

      if (res.statusCode != 200) {
        return 'GitHub search API error: ${res.statusCode} ${res.reasonPhrase}';
      }

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final totalCount = data['total_count'] as int? ?? 0;
      final items = (data['items'] as List?)?.cast<Map<String, dynamic>>() ?? [];

      if (items.isEmpty) {
        return 'No results found for "$query" in $repo';
      }

      final lines = items.map((item) {
        final path = item['path'] as String;
        final name = item['name'] as String;
        return '📄 $path ($name)';
      });

      return '$totalCount result(s) for "$query" in $repo:\n\n'
          '${lines.join("\n")}';
    },
  );
}

CustomToolDef _createGitHubIssueTool(
  String token,
  String defaultRepo,
  http.Client client,
) {
  return CustomToolDef(
    name: 'create_github_issue',
    description: 'Create a new issue on a GitHub repository. '
        'Use this to file bugs, feature requests, or track tasks. '
        'Returns the issue number and URL.',
    inputSchema: <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'title': <String, dynamic>{
          'type': 'string',
          'description': 'Issue title',
        },
        'body': <String, dynamic>{
          'type': 'string',
          'description': 'Issue body (supports GitHub Markdown)',
        },
        'labels': <String, dynamic>{
          'type': 'array',
          'items': <String, dynamic>{'type': 'string'},
          'description': "Labels to apply (e.g. ['bug']). Must already exist.",
        },
        'repo': <String, dynamic>{
          'type': 'string',
          'description':
              'Repository in owner/name format (default: $defaultRepo)',
        },
      },
      'required': <String>['title'],
    },
    handler: (args) async {
      final repo = args['repo'] as String? ?? defaultRepo;
      final payload = <String, dynamic>{
        'title': args['title'] as String,
      };
      if (args['body'] != null) payload['body'] = args['body'] as String;
      if (args['labels'] is List) payload['labels'] = args['labels'];

      final res = await _ghFetch(
        client,
        token,
        '/repos/$repo/issues',
        method: 'POST',
        body: payload,
      );

      if (res.statusCode != 201) {
        return 'Failed to create issue: ${res.statusCode} ${res.reasonPhrase}\n'
            '${res.body}';
      }

      final issue = jsonDecode(res.body) as Map<String, dynamic>;
      return jsonEncode(<String, dynamic>{
        'success': true,
        'number': issue['number'],
        'url': issue['html_url'],
        'title': issue['title'],
      });
    },
  );
}

CustomToolDef _listGitHubIssuesTool(
  String token,
  String defaultRepo,
  http.Client client,
) {
  return CustomToolDef(
    name: 'list_github_issues',
    description: 'List issues on a GitHub repository. '
        'Useful for checking existing bugs or reviewing open work.',
    inputSchema: <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'state': <String, dynamic>{
          'type': 'string',
          'description':
              "Filter by state: 'open', 'closed', or 'all' (default: 'open')",
        },
        'labels': <String, dynamic>{
          'type': 'string',
          'description':
              "Comma-separated label names to filter (e.g. 'bug,priority:high')",
        },
        'limit': <String, dynamic>{
          'type': 'number',
          'description': 'Max issues to return (default: 10, max: 30)',
        },
        'repo': <String, dynamic>{
          'type': 'string',
          'description':
              'Repository in owner/name format (default: $defaultRepo)',
        },
      },
    },
    handler: (args) async {
      final repo = args['repo'] as String? ?? defaultRepo;
      final state = args['state'] as String? ?? 'open';
      final limit = ((args['limit'] as num?)?.toInt() ?? 10).clamp(1, 30);

      final params = <String, String>{
        'state': state,
        'per_page': '$limit',
        'sort': 'updated',
        'direction': 'desc',
      };
      if (args['labels'] != null) {
        params['labels'] = args['labels'] as String;
      }

      final query = params.entries.map((e) => '${e.key}=${e.value}').join('&');
      final res = await _ghFetch(
        client,
        token,
        '/repos/$repo/issues?$query',
      );

      if (res.statusCode != 200) {
        return 'GitHub API error: ${res.statusCode} ${res.reasonPhrase}';
      }

      final issues = (jsonDecode(res.body) as List)
          .cast<Map<String, dynamic>>()
          // GitHub API returns PRs as issues — filter them out.
          .where((i) => i['pull_request'] == null)
          .toList();

      if (issues.isEmpty) {
        final labelNote = args['labels'] != null
            ? ' with labels: ${args['labels']}'
            : '';
        return 'No $state issues found$labelNote in $repo';
      }

      final lines = issues.map((i) {
        final labels = (i['labels'] as List)
            .cast<Map<String, dynamic>>()
            .map((l) => l['name'])
            .join(', ');
        final updated = (i['updated_at'] as String).substring(0, 10);
        final buf = StringBuffer()
          ..writeln('#${i['number']}: ${i['title']}')
          ..writeln('  State: ${i['state']} | Updated: $updated');
        if (labels.isNotEmpty) buf.writeln('  Labels: $labels');
        buf.write('  ${i['html_url']}');
        return buf.toString();
      });

      return '${issues.length} issue(s) in $repo:\n\n${lines.join("\n\n")}';
    },
  );
}
