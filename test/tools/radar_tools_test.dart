import 'dart:convert';

import 'package:dreamfinder/src/agent/tool_registry.dart';
import 'package:dreamfinder/src/db/database.dart';
import 'package:dreamfinder/src/db/queries.dart';
import 'package:dreamfinder/src/db/schema.dart';
import 'package:dreamfinder/src/tools/radar_tools.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

void main() {
  late ToolRegistry registry;
  late BotDatabase db;
  late Queries queries;

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

  /// Helper to call a tool and parse JSON result.
  Future<Map<String, dynamic>> callJson(
    String toolName,
    Map<String, dynamic> args, {
    bool isAdmin = true,
  }) async {
    registry.setContext(ToolContext(
      senderId: 'test-user',
      isAdmin: isAdmin,
      chatId: 'room-1',
    ));
    final result = await registry.executeTool(toolName, args);
    return jsonDecode(result) as Map<String, dynamic>;
  }

  /// Helper to call a tool and return raw string result.
  Future<String> callRaw(
    String toolName,
    Map<String, dynamic> args, {
    bool isAdmin = true,
  }) async {
    registry.setContext(ToolContext(
      senderId: 'test-user',
      isAdmin: isAdmin,
      chatId: 'room-1',
    ));
    return registry.executeTool(toolName, args);
  }

  setUp(() {
    db = BotDatabase.inMemory();
    queries = Queries(db);
    registry = ToolRegistry();
  });

  tearDown(() {
    db.close();
  });

  group('registerRadarTools', () {
    test('does not register tools when token is null', () {
      registerRadarTools(registry, queries: queries, token: null);
      final tools = registry.getAllToolDefinitions();
      final radarTools = tools
          .where((ToolDefinition t) => t.name.contains('radar') ||
              t.name.contains('track') ||
              t.name.contains('contribution') ||
              t.name.contains('crawl') ||
              t.name.contains('star_repo'))
          .toList();
      expect(radarTools, isEmpty);
    });

    test('registers all radar tools when token is provided', () {
      registerRadarTools(registry, queries: queries, token: 'test-token');
      final tools = registry.getAllToolDefinitions();
      final names = tools.map((ToolDefinition t) => t.name).toSet();
      expect(names, contains('track_repo'));
      expect(names, contains('list_tracked_repos'));
      expect(names, contains('crawl_repo'));
      expect(names, contains('star_repo'));
      expect(names, contains('draft_contribution'));
      expect(names, contains('list_contribution_drafts'));
      expect(names, contains('submit_contribution'));
    });
  });

  group('track_repo', () {
    setUp(() {
      registerRadarTools(
        registry,
        queries: queries,
        token: 'test-token',
        httpClient: mockClient(''),
      );
    });

    test('tracks a new repo with reason', () async {
      final result = await callJson('track_repo', {
        'repo': 'dart-lang/sdk',
        'reason': 'Core language SDK — relevant to our Dart tooling',
      });

      expect(result['success'], isTrue);
      expect(result['repo'], 'dart-lang/sdk');

      final tracked = queries.getTrackedRepo('dart-lang/sdk');
      expect(tracked, isNotNull);
      expect(tracked!.reason, contains('Core language SDK'));
      expect(tracked.sourceChatId, 'room-1');
    });

    test('updates reason when tracking an existing repo', () async {
      await callJson('track_repo', {
        'repo': 'dart-lang/sdk',
        'reason': 'Initial reason',
      });
      await callJson('track_repo', {
        'repo': 'dart-lang/sdk',
        'reason': 'Updated reason with more context',
      });

      final tracked = queries.getTrackedRepo('dart-lang/sdk');
      expect(tracked!.reason, 'Updated reason with more context');
    });

    test('stores source message when provided', () async {
      await callJson('track_repo', {
        'repo': 'flutter/flutter',
        'reason': 'Mobile framework',
        'source_message': 'We should check out Flutter for the mobile app',
      });

      final tracked = queries.getTrackedRepo('flutter/flutter');
      expect(tracked!.sourceMessage, contains('check out Flutter'));
    });
  });

  group('list_tracked_repos', () {
    setUp(() {
      registerRadarTools(
        registry,
        queries: queries,
        token: 'test-token',
        httpClient: mockClient(''),
      );
    });

    test('returns empty message when no repos tracked', () async {
      final result = await callJson('list_tracked_repos', {});
      expect(result['repos'], isEmpty);
    });

    test('returns all tracked repos', () async {
      queries.upsertTrackedRepo(
        repo: 'dart-lang/sdk',
        reason: 'Core SDK',
        sourceChatId: 'room-1',
      );
      queries.upsertTrackedRepo(
        repo: 'flutter/flutter',
        reason: 'Mobile framework',
        sourceChatId: 'room-1',
      );

      final result = await callJson('list_tracked_repos', {});
      final repos = result['repos'] as List;
      expect(repos, hasLength(2));
    });

    test('filters by chat when chat_id provided', () async {
      queries.upsertTrackedRepo(
        repo: 'dart-lang/sdk',
        reason: 'Core SDK',
        sourceChatId: 'room-1',
      );
      queries.upsertTrackedRepo(
        repo: 'flutter/flutter',
        reason: 'Mobile framework',
        sourceChatId: 'room-2',
      );

      registry.setContext(ToolContext(
        senderId: 'test-user',
        isAdmin: true,
        chatId: 'room-1',
      ));
      final result = await callJson('list_tracked_repos', {
        'chat_id': 'room-1',
      });
      final repos = result['repos'] as List;
      expect(repos, hasLength(1));
      expect((repos.first as Map)['repo'], 'dart-lang/sdk');
    });
  });

  group('crawl_repo', () {
    test('fetches and stores repo metadata from GitHub', () async {
      final ghResponse = jsonEncode({
        'full_name': 'dart-lang/sdk',
        'description': 'The Dart SDK',
        'stargazers_count': 10000,
        'language': 'Dart',
        'topics': ['dart', 'sdk'],
        'open_issues_count': 500,
        'updated_at': '2026-03-25T00:00:00Z',
        'license': {'spdx_id': 'BSD-3-Clause'},
      });

      registerRadarTools(
        registry,
        queries: queries,
        token: 'test-token',
        httpClient: mockClient(ghResponse),
      );

      queries.upsertTrackedRepo(
        repo: 'dart-lang/sdk',
        reason: 'Core SDK',
        sourceChatId: 'room-1',
      );

      final result = await callJson('crawl_repo', {
        'repo': 'dart-lang/sdk',
      });

      expect(result['success'], isTrue);
      expect(result['metadata']['stars'], 10000);
      expect(result['metadata']['language'], 'Dart');
      expect(result['metadata']['description'], 'The Dart SDK');

      // Verify persisted to DB.
      final tracked = queries.getTrackedRepo('dart-lang/sdk');
      expect(tracked!.metadata, isNotNull);
      expect(tracked.lastCrawledAt, isNotNull);
    });

    test('auto-tracks repo if not already tracked', () async {
      final ghResponse = jsonEncode({
        'full_name': 'new/repo',
        'description': 'A new repo',
        'stargazers_count': 42,
        'language': 'Go',
        'topics': <String>[],
        'open_issues_count': 3,
        'updated_at': '2026-03-25T00:00:00Z',
      });

      registerRadarTools(
        registry,
        queries: queries,
        token: 'test-token',
        httpClient: mockClient(ghResponse),
      );

      final result = await callJson('crawl_repo', {
        'repo': 'new/repo',
      });

      expect(result['success'], isTrue);
      final tracked = queries.getTrackedRepo('new/repo');
      expect(tracked, isNotNull);
      expect(tracked!.reason, contains('Crawled'));
    });

    test('returns error for non-existent repo', () async {
      registerRadarTools(
        registry,
        queries: queries,
        token: 'test-token',
        httpClient: mockClient('Not Found', statusCode: 404),
      );

      final result = await callJson('crawl_repo', {
        'repo': 'nonexistent/repo',
      });

      expect(result['error'], isNotNull);
    });
  });

  group('star_repo', () {
    test('stars repo on GitHub and marks in DB', () async {
      http.BaseRequest? capturedRequest;
      final client = http_testing.MockClient((request) async {
        capturedRequest = request;
        return http.Response('', 204); // GitHub returns 204 for star.
      });

      registerRadarTools(
        registry,
        queries: queries,
        token: 'test-token',
        httpClient: client,
      );

      queries.upsertTrackedRepo(
        repo: 'dart-lang/sdk',
        reason: 'Core SDK',
        sourceChatId: 'room-1',
      );

      final result = await callJson('star_repo', {
        'repo': 'dart-lang/sdk',
      });

      expect(result['success'], isTrue);
      expect(capturedRequest!.method, 'PUT');
      expect(capturedRequest!.url.path, contains('dart-lang/sdk'));

      final tracked = queries.getTrackedRepo('dart-lang/sdk');
      expect(tracked!.starred, isTrue);
    });

    test('auto-tracks repo if not already tracked', () async {
      registerRadarTools(
        registry,
        queries: queries,
        token: 'test-token',
        httpClient: mockClient('', statusCode: 204),
      );

      await callJson('star_repo', {'repo': 'new/repo'});

      final tracked = queries.getTrackedRepo('new/repo');
      expect(tracked, isNotNull);
      expect(tracked!.starred, isTrue);
    });
  });

  group('draft_contribution', () {
    setUp(() {
      registerRadarTools(
        registry,
        queries: queries,
        token: 'test-token',
        httpClient: mockClient(''),
      );
    });

    test('creates an issue draft', () async {
      final result = await callJson('draft_contribution', {
        'repo': 'dart-lang/sdk',
        'type': 'issue',
        'title': 'Support for X feature',
        'body': '## Problem\nWe need X.\n\n## Proposal\nDo Y.',
      });

      expect(result['success'], isTrue);
      expect(result['draft_id'], isA<int>());

      final drafts = queries.getContributionDrafts();
      expect(drafts, hasLength(1));
      expect(drafts.first.type, ContributionType.issue);
      expect(drafts.first.title, 'Support for X feature');
      expect(drafts.first.status, ContributionDraftStatus.draft);
    });

    test('creates a PR draft with target branch', () async {
      final result = await callJson('draft_contribution', {
        'repo': 'dart-lang/sdk',
        'type': 'pr',
        'title': 'Fix typo in README',
        'body': 'Small typo fix.',
        'target_branch': 'main',
      });

      expect(result['success'], isTrue);

      final draft = queries.getContributionDraft(result['draft_id'] as int);
      expect(draft!.type, ContributionType.pr);
      expect(draft.targetBranch, 'main');
    });
  });

  group('list_contribution_drafts', () {
    setUp(() {
      registerRadarTools(
        registry,
        queries: queries,
        token: 'test-token',
        httpClient: mockClient(''),
      );
    });

    test('returns empty list when no drafts', () async {
      final result = await callJson('list_contribution_drafts', {});
      expect(result['drafts'], isEmpty);
    });

    test('returns all drafts', () async {
      queries.createContributionDraft(
        repo: 'dart-lang/sdk',
        type: ContributionType.issue,
        title: 'Issue 1',
        body: 'Body 1',
      );
      queries.createContributionDraft(
        repo: 'flutter/flutter',
        type: ContributionType.pr,
        title: 'PR 1',
        body: 'Body 2',
        targetBranch: 'main',
      );

      final result = await callJson('list_contribution_drafts', {});
      final drafts = result['drafts'] as List;
      expect(drafts, hasLength(2));
    });

    test('filters by status', () async {
      final id = queries.createContributionDraft(
        repo: 'dart-lang/sdk',
        type: ContributionType.issue,
        title: 'Submitted one',
        body: 'Body',
      );
      queries.markDraftSubmitted(id, 'https://github.com/dart-lang/sdk/issues/1');
      queries.createContributionDraft(
        repo: 'dart-lang/sdk',
        type: ContributionType.issue,
        title: 'Still a draft',
        body: 'Body',
      );

      final result = await callJson('list_contribution_drafts', {
        'status': 'draft',
      });
      final drafts = result['drafts'] as List;
      expect(drafts, hasLength(1));
      expect((drafts.first as Map)['title'], 'Still a draft');
    });

    test('filters by repo', () async {
      queries.createContributionDraft(
        repo: 'dart-lang/sdk',
        type: ContributionType.issue,
        title: 'SDK issue',
        body: 'Body',
      );
      queries.createContributionDraft(
        repo: 'flutter/flutter',
        type: ContributionType.issue,
        title: 'Flutter issue',
        body: 'Body',
      );

      final result = await callJson('list_contribution_drafts', {
        'repo': 'dart-lang/sdk',
      });
      final drafts = result['drafts'] as List;
      expect(drafts, hasLength(1));
      expect((drafts.first as Map)['title'], 'SDK issue');
    });
  });

  group('submit_contribution', () {
    test('requires admin privileges', () async {
      registerRadarTools(
        registry,
        queries: queries,
        token: 'test-token',
        httpClient: mockClient(''),
      );

      final id = queries.createContributionDraft(
        repo: 'dart-lang/sdk',
        type: ContributionType.issue,
        title: 'Test issue',
        body: 'Body',
      );

      final result = await callRaw('submit_contribution', {
        'draft_id': id,
      }, isAdmin: false);

      expect(result, contains('admin'));
    });

    test('submits an issue draft to GitHub', () async {
      final ghResponse = jsonEncode({
        'number': 42,
        'html_url': 'https://github.com/dart-lang/sdk/issues/42',
        'title': 'Test issue',
      });

      http.BaseRequest? capturedRequest;
      registerRadarTools(
        registry,
        queries: queries,
        token: 'test-token',
        httpClient: http_testing.MockClient((request) async {
          capturedRequest = request;
          return http.Response(ghResponse, 201);
        }),
      );

      final id = queries.createContributionDraft(
        repo: 'dart-lang/sdk',
        type: ContributionType.issue,
        title: 'Test issue',
        body: 'Issue body',
      );

      final result = await callJson('submit_contribution', {
        'draft_id': id,
      });

      expect(result['success'], isTrue);
      expect(result['url'], contains('issues/42'));
      expect(capturedRequest!.url.path, contains('/repos/dart-lang/sdk/issues'));

      final draft = queries.getContributionDraft(id);
      expect(draft!.status, ContributionDraftStatus.submitted);
      expect(draft.submittedUrl, contains('issues/42'));
    });

    test('returns error for non-existent draft', () async {
      registerRadarTools(
        registry,
        queries: queries,
        token: 'test-token',
        httpClient: mockClient(''),
      );

      final result = await callJson('submit_contribution', {
        'draft_id': 999,
      });

      expect(result['error'], isNotNull);
    });

    test('returns error for already-submitted draft', () async {
      registerRadarTools(
        registry,
        queries: queries,
        token: 'test-token',
        httpClient: mockClient(''),
      );

      final id = queries.createContributionDraft(
        repo: 'dart-lang/sdk',
        type: ContributionType.issue,
        title: 'Test',
        body: 'Body',
      );
      queries.markDraftSubmitted(id, 'https://github.com/dart-lang/sdk/issues/1');

      final result = await callJson('submit_contribution', {
        'draft_id': id,
      });

      expect(result['error'], contains('already'));
    });
  });
}
