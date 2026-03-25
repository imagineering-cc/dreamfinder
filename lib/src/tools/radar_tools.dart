/// Repo Radar tools — discover interesting repos from conversation, track them,
/// crawl metadata, star them, and draft contributions for human review.
///
/// Tools:
/// - `track_repo`: Track a repo spotted in conversation.
/// - `list_tracked_repos`: List all tracked repos.
/// - `crawl_repo`: Fetch/refresh metadata from GitHub API.
/// - `star_repo`: Star a repo on the Dreamfinder GitHub account.
/// - `draft_contribution`: Draft a PR or issue for human review.
/// - `list_contribution_drafts`: List pending drafts.
/// - `submit_contribution`: Submit a draft to GitHub (admin-only).
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../agent/tool_registry.dart';
import '../db/queries.dart';
import '../db/schema.dart';

/// Registers Repo Radar tools with the [ToolRegistry].
///
/// If [token] is null or empty, no tools are registered (GitHub API required).
void registerRadarTools(
  ToolRegistry registry, {
  required Queries queries,
  required String? token,
  http.Client? httpClient,
}) {
  if (token == null || token.isEmpty) return;

  final client = httpClient ?? http.Client();

  registry.registerCustomTool(_trackRepoTool(registry, queries));
  registry.registerCustomTool(_listTrackedReposTool(queries));
  registry.registerCustomTool(_crawlRepoTool(registry, queries, token, client));
  registry.registerCustomTool(_starRepoTool(registry, queries, token, client));
  registry.registerCustomTool(_draftContributionTool(queries));
  registry.registerCustomTool(_listContributionDraftsTool(queries));
  registry.registerCustomTool(_submitContributionTool(queries, token, client));
}

// ---------------------------------------------------------------------------
// GitHub API helper
// ---------------------------------------------------------------------------

Future<http.Response> _ghApi(
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

  switch (method) {
    case 'PUT':
      headers['Content-Length'] = '0'; // GitHub star API requires empty body.
      return client.put(uri, headers: headers);
    case 'POST':
      headers['Content-Type'] = 'application/json';
      return client.post(uri, headers: headers, body: jsonEncode(body));
    default:
      return client.get(uri, headers: headers);
  }
}

// ---------------------------------------------------------------------------
// track_repo
// ---------------------------------------------------------------------------

CustomToolDef _trackRepoTool(ToolRegistry registry, Queries queries) {
  return CustomToolDef(
    name: 'track_repo',
    description: 'Track an interesting GitHub repository spotted in '
        'conversation. Call this when you notice a repo being discussed '
        'that could be useful to the team. The repo will be added to the '
        'Repo Radar for monitoring and potential contribution.',
    inputSchema: <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'repo': <String, dynamic>{
          'type': 'string',
          'description':
              "Repository in owner/name format (e.g. 'dart-lang/sdk')",
        },
        'reason': <String, dynamic>{
          'type': 'string',
          'description': 'Why this repo is interesting or relevant to the team',
        },
        'source_message': <String, dynamic>{
          'type': 'string',
          'description':
              'The message that referenced this repo (for context)',
        },
      },
      'required': <String>['repo', 'reason'],
    },
    handler: (args) async {
      final repo = args['repo'] as String;
      final reason = args['reason'] as String;
      final sourceMessage = args['source_message'] as String?;

      final chatId = registry.context?.chatId ?? 'unknown';

      queries.upsertTrackedRepo(
        repo: repo,
        reason: reason,
        sourceChatId: chatId,
        sourceMessage: sourceMessage,
      );

      return jsonEncode(<String, dynamic>{
        'success': true,
        'repo': repo,
        'message': 'Now tracking $repo on the Repo Radar.',
      });
    },
  );
}

// ---------------------------------------------------------------------------
// list_tracked_repos
// ---------------------------------------------------------------------------

CustomToolDef _listTrackedReposTool(Queries queries) {
  return CustomToolDef(
    name: 'list_tracked_repos',
    description: 'List all repositories on the Repo Radar. Optionally filter '
        'by the chat where they were discovered.',
    inputSchema: <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'chat_id': <String, dynamic>{
          'type': 'string',
          'description': 'Filter to repos discovered in this chat',
        },
      },
    },
    handler: (args) async {
      final chatId = args['chat_id'] as String?;

      final repos = chatId != null
          ? queries.getTrackedReposForChat(chatId)
          : queries.getAllTrackedRepos();

      return jsonEncode(<String, dynamic>{
        'repos': repos
            .map((r) => <String, dynamic>{
                  'repo': r.repo,
                  'reason': r.reason,
                  'starred': r.starred,
                  'tracked_at': r.trackedAt,
                  'last_crawled_at': r.lastCrawledAt,
                  if (r.metadata != null)
                    'metadata': jsonDecode(r.metadata!),
                })
            .toList(),
      });
    },
  );
}

// ---------------------------------------------------------------------------
// crawl_repo
// ---------------------------------------------------------------------------

CustomToolDef _crawlRepoTool(
  ToolRegistry registry,
  Queries queries,
  String token,
  http.Client client,
) {
  return CustomToolDef(
    name: 'crawl_repo',
    description: 'Fetch or refresh metadata for a GitHub repository. '
        'Gets stars, description, language, topics, and open issues. '
        'Auto-tracks the repo if not already on the Radar.',
    inputSchema: <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'repo': <String, dynamic>{
          'type': 'string',
          'description':
              "Repository in owner/name format (e.g. 'dart-lang/sdk')",
        },
      },
      'required': <String>['repo'],
    },
    handler: (args) async {
      final repo = args['repo'] as String;

      final res = await _ghApi(client, token, '/repos/$repo');

      if (res.statusCode == 404) {
        return jsonEncode(<String, dynamic>{
          'error': 'Repository not found: $repo',
        });
      }
      if (res.statusCode != 200) {
        return jsonEncode(<String, dynamic>{
          'error': 'GitHub API error: ${res.statusCode} ${res.reasonPhrase}',
        });
      }

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final metadata = <String, dynamic>{
        'description': data['description'],
        'stars': data['stargazers_count'],
        'language': data['language'],
        'topics': data['topics'],
        'open_issues': data['open_issues_count'],
        'updated_at': data['updated_at'],
        if (data['license'] is Map)
          'license': (data['license'] as Map)['spdx_id'],
      };

      // Auto-track if not already tracked.
      if (queries.getTrackedRepo(repo) == null) {
        queries.upsertTrackedRepo(
          repo: repo,
          reason: 'Crawled via Repo Radar',
          sourceChatId: registry.context?.chatId ?? 'unknown',
        );
      }

      queries.updateRepoMetadata(repo, jsonEncode(metadata));

      return jsonEncode(<String, dynamic>{
        'success': true,
        'repo': repo,
        'metadata': metadata,
      });
    },
  );
}

// ---------------------------------------------------------------------------
// star_repo
// ---------------------------------------------------------------------------

CustomToolDef _starRepoTool(
  ToolRegistry registry,
  Queries queries,
  String token,
  http.Client client,
) {
  return CustomToolDef(
    name: 'star_repo',
    description: 'Star a GitHub repository on the Dreamfinder account. '
        'This is a lightweight way to bookmark interesting repos. '
        'No notification is sent to the repo maintainer.',
    inputSchema: <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'repo': <String, dynamic>{
          'type': 'string',
          'description':
              "Repository in owner/name format (e.g. 'dart-lang/sdk')",
        },
      },
      'required': <String>['repo'],
    },
    handler: (args) async {
      final repo = args['repo'] as String;

      final res = await _ghApi(
        client,
        token,
        '/user/starred/$repo',
        method: 'PUT',
      );

      if (res.statusCode != 204 && res.statusCode != 304) {
        return jsonEncode(<String, dynamic>{
          'error': 'Failed to star repo: ${res.statusCode} ${res.reasonPhrase}',
        });
      }

      // Auto-track if not already tracked.
      if (queries.getTrackedRepo(repo) == null) {
        queries.upsertTrackedRepo(
          repo: repo,
          reason: 'Starred via Repo Radar',
          sourceChatId: registry.context?.chatId ?? 'unknown',
        );
      }

      queries.markRepoStarred(repo);

      return jsonEncode(<String, dynamic>{
        'success': true,
        'repo': repo,
        'message': 'Starred $repo on GitHub.',
      });
    },
  );
}

// ---------------------------------------------------------------------------
// draft_contribution
// ---------------------------------------------------------------------------

CustomToolDef _draftContributionTool(Queries queries) {
  return CustomToolDef(
    name: 'draft_contribution',
    description: 'Draft a PR or issue for a GitHub repository. The draft is '
        'stored locally for human review — nothing is sent to GitHub until '
        'an admin uses submit_contribution. Write high-quality, specific '
        'titles and well-structured Markdown bodies.',
    inputSchema: <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'repo': <String, dynamic>{
          'type': 'string',
          'description':
              "Repository in owner/name format (e.g. 'dart-lang/sdk')",
        },
        'type': <String, dynamic>{
          'type': 'string',
          'enum': ['pr', 'issue'],
          'description': "Type of contribution: 'pr' or 'issue'",
        },
        'title': <String, dynamic>{
          'type': 'string',
          'description': 'Title for the PR or issue',
        },
        'body': <String, dynamic>{
          'type': 'string',
          'description': 'Body/description in GitHub Markdown',
        },
        'target_branch': <String, dynamic>{
          'type': 'string',
          'description': "Target branch for PRs (e.g. 'main'). "
              'Ignored for issues.',
        },
      },
      'required': <String>['repo', 'type', 'title', 'body'],
    },
    handler: (args) async {
      final repo = args['repo'] as String;
      final type = ContributionType.fromDb(args['type'] as String);
      final title = args['title'] as String;
      final body = args['body'] as String;
      final targetBranch = args['target_branch'] as String?;

      final id = queries.createContributionDraft(
        repo: repo,
        type: type,
        title: title,
        body: body,
        targetBranch: targetBranch,
      );

      return jsonEncode(<String, dynamic>{
        'success': true,
        'draft_id': id,
        'message': 'Draft ${type.dbValue} created for $repo. '
            'An admin can review and submit it with submit_contribution.',
      });
    },
  );
}

// ---------------------------------------------------------------------------
// list_contribution_drafts
// ---------------------------------------------------------------------------

CustomToolDef _listContributionDraftsTool(Queries queries) {
  return CustomToolDef(
    name: 'list_contribution_drafts',
    description: 'List contribution drafts (PRs and issues) awaiting review. '
        'Filter by status or repo.',
    inputSchema: <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'status': <String, dynamic>{
          'type': 'string',
          'enum': ['draft', 'submitted', 'rejected'],
          'description': 'Filter by status (default: all)',
        },
        'repo': <String, dynamic>{
          'type': 'string',
          'description': 'Filter to drafts for a specific repo',
        },
      },
    },
    handler: (args) async {
      final statusStr = args['status'] as String?;
      final repo = args['repo'] as String?;

      List<ContributionDraftRecord> drafts;
      if (repo != null) {
        drafts = queries.getContributionDraftsForRepo(repo);
        if (statusStr != null) {
          final status = ContributionDraftStatus.fromDb(statusStr);
          drafts = drafts.where((d) => d.status == status).toList();
        }
      } else if (statusStr != null) {
        drafts = queries.getContributionDrafts(
          status: ContributionDraftStatus.fromDb(statusStr),
        );
      } else {
        drafts = queries.getContributionDrafts();
      }

      return jsonEncode(<String, dynamic>{
        'drafts': drafts
            .map((d) => <String, dynamic>{
                  'id': d.id,
                  'repo': d.repo,
                  'type': d.type.dbValue,
                  'title': d.title,
                  'body': d.body,
                  'status': d.status.dbValue,
                  'created_at': d.createdAt,
                  if (d.targetBranch != null) 'target_branch': d.targetBranch,
                  if (d.submittedUrl != null) 'submitted_url': d.submittedUrl,
                })
            .toList(),
      });
    },
  );
}

// ---------------------------------------------------------------------------
// submit_contribution
// ---------------------------------------------------------------------------

CustomToolDef _submitContributionTool(
  Queries queries,
  String token,
  http.Client client,
) {
  return CustomToolDef(
    name: 'submit_contribution',
    description: 'Submit a reviewed contribution draft to GitHub. Creates the '
        'issue or PR on the target repository. Admin-only — this is the '
        'human-in-the-loop gate.',
    requiresAdmin: true,
    inputSchema: <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'draft_id': <String, dynamic>{
          'type': 'integer',
          'description': 'ID of the contribution draft to submit',
        },
      },
      'required': <String>['draft_id'],
    },
    handler: (args) async {
      final draftId = args['draft_id'] as int;

      final draft = queries.getContributionDraft(draftId);
      if (draft == null) {
        return jsonEncode(<String, dynamic>{
          'error': 'Draft not found: $draftId',
        });
      }

      if (draft.status != ContributionDraftStatus.draft) {
        return jsonEncode(<String, dynamic>{
          'error': 'Draft $draftId has already been ${draft.status.dbValue}.',
        });
      }

      // Currently only issue submission is supported.
      // PR submission requires fork + branch + push, which is a future feature.
      if (draft.type == ContributionType.pr) {
        return jsonEncode(<String, dynamic>{
          'error': 'PR submission is not yet supported. '
              'PR drafts must be submitted manually for now. '
              'Use the draft body as a starting point.',
        });
      }

      final payload = <String, dynamic>{
        'title': draft.title,
        'body': draft.body,
      };

      final res = await _ghApi(
        client,
        token,
        '/repos/${draft.repo}/issues',
        method: 'POST',
        body: payload,
      );

      if (res.statusCode != 201) {
        return jsonEncode(<String, dynamic>{
          'error': 'Failed to create issue: ${res.statusCode} '
              '${res.reasonPhrase}\n${res.body}',
        });
      }

      final issue = jsonDecode(res.body) as Map<String, dynamic>;
      final url = issue['html_url'] as String;

      queries.markDraftSubmitted(draftId, url);

      return jsonEncode(<String, dynamic>{
        'success': true,
        'number': issue['number'],
        'url': url,
        'title': issue['title'],
        'message': 'Issue created successfully on ${draft.repo}.',
      });
    },
  );
}
