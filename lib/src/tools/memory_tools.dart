/// Custom tools for the RAG memory system.
///
/// - `save_memory`: Explicitly save information to long-term memory.
/// - `search_memory`: Actively search past conversations and saved knowledge.
/// - `deep_search`: Parallel multi-source search across memory, Outline, and
///   Kan — the agentic RAG tool for cross-cutting questions.
library;

import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import '../agent/tool_registry.dart';
import '../memory/embedding_pipeline.dart';
import '../memory/memory_record.dart';
import '../memory/memory_retriever.dart';
import 'cli_tools.dart'
    show
        CliCompleted,
        CliLaunchFailure,
        CliOutcome,
        CliTimeout,
        execVendoredCli;

/// Runs a vendored CLI and returns its [CliOutcome]. Defaults to the real
/// [execVendoredCli]; injectable so `deep_search` tests can supply canned
/// output without spawning a `node` subprocess.
typedef CliRunner = Future<CliOutcome> Function({
  required String tool,
  required List<String> args,
  required Map<String, String> env,
});

/// Registers memory tools with the [ToolRegistry].
///
/// When [pipeline] is `null` (no `VOYAGE_API_KEY`), the save tool is still
/// registered but returns an error when invoked — this lets the agent explain
/// the limitation to the user. Same pattern for [retriever] and search.
///
/// `deep_search` fans out to Outline and Kan via the vendored CLIs (the same
/// `run_cli` path), not MCP — the Outline/Kan MCP servers were retired in the
/// run_cli migration, which silently left `deep_search` searching nothing. The
/// Outline arm is available whenever [outlineApiKey]/[outlineBaseUrl] are set;
/// the Kan arm additionally needs [kanWorkspaceId] (the CLI's `search` requires
/// a workspace). [cliRunner] is injectable for tests.
void registerMemoryTools(
  ToolRegistry registry,
  EmbeddingPipeline? pipeline,
  MemoryRetriever? retriever, {
  String? outlineApiKey,
  String? outlineBaseUrl,
  String? kanApiKey,
  String? kanBaseUrl,
  String? kanWorkspaceId,
  CliRunner cliRunner = execVendoredCli,
}) {
  registry.registerCustomTool(_saveMemoryTool(registry, pipeline));
  registry.registerCustomTool(_searchMemoryTool(registry, retriever));
  registry.registerCustomTool(
    _deepSearchTool(
      registry,
      retriever,
      outlineApiKey: outlineApiKey,
      outlineBaseUrl: outlineBaseUrl,
      kanApiKey: kanApiKey,
      kanBaseUrl: kanBaseUrl,
      kanWorkspaceId: kanWorkspaceId,
      cliRunner: cliRunner,
    ),
  );
}

CustomToolDef _saveMemoryTool(
  ToolRegistry registry,
  EmbeddingPipeline? pipeline,
) {
  return CustomToolDef(
    name: 'save_memory',
    description: 'Explicitly save a piece of information to long-term memory. '
        'Use this when a user says "remember this", "keep this in mind", '
        '"remember this everywhere", or similar. The content will be embedded '
        'and retrievable in future conversations.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'content': <String, dynamic>{
          'type': 'string',
          'description': 'The information to remember.',
        },
        'visibility': <String, dynamic>{
          'type': 'string',
          'enum': ['same_chat', 'cross_chat', 'private'],
          'description': 'Where this memory should be retrievable. '
              '"same_chat" = only this chat (default), '
              '"cross_chat" = all chats, '
              '"private" = only this 1:1 conversation.',
        },
      },
      'required': <String>['content'],
    },
    handler: (args) async {
      if (pipeline == null) {
        return jsonEncode(<String, dynamic>{
          'error': 'Long-term memory is not enabled — '
              'the VOYAGE_API_KEY environment variable is not set.',
        });
      }

      final content = (args['content'] as String).trim();
      if (content.isEmpty) {
        return jsonEncode(<String, dynamic>{
          'error': 'Content is empty — nothing to remember.',
        });
      }
      final visibilityStr = args['visibility'] as String?;
      final visibility = switch (visibilityStr) {
        'cross_chat' => MemoryVisibility.crossChat,
        'private' => MemoryVisibility.private_,
        _ => MemoryVisibility.sameChat,
      };

      final ctx = registry.context;
      pipeline.queue(
        chatId: ctx?.chatId ?? 'unknown',
        userText: '[Explicit save] $content',
        assistantText: '(saved to memory)',
        senderId: ctx?.senderId,
        visibility: visibility,
      );

      return jsonEncode(<String, dynamic>{
        'success': true,
        'visibility': visibility.dbValue,
        'content_length': content.length,
      });
    },
  );
}

CustomToolDef _searchMemoryTool(
  ToolRegistry registry,
  MemoryRetriever? retriever,
) {
  return CustomToolDef(
    name: 'search_memory',
    description: 'Search past conversations and saved knowledge from long-term '
        'memory. Use this when passive recall does not surface what you need, '
        'or when a user asks "do you remember..." or "what did we discuss '
        'about...". Returns the most relevant memories ranked by similarity.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'query': <String, dynamic>{
          'type': 'string',
          'description': 'The search query — a natural language description of '
              'what you are looking for.',
        },
        'limit': <String, dynamic>{
          'type': 'integer',
          'description': 'Maximum number of results to return (1–10, '
              'default 5).',
        },
      },
      'required': <String>['query'],
    },
    handler: (args) async {
      if (retriever == null) {
        return jsonEncode(<String, dynamic>{
          'error': 'Long-term memory search is not enabled — '
              'the VOYAGE_API_KEY environment variable is not set.',
        });
      }

      final query = (args['query'] as String).trim();
      if (query.isEmpty) {
        return jsonEncode(<String, dynamic>{
          'error': 'Query is empty — nothing to search for.',
        });
      }

      final limit = (args['limit'] as int? ?? 5).clamp(1, 10);

      final ctx = registry.context;
      final chatId = ctx?.chatId ?? 'unknown';

      final results = await retriever.retrieve(
        query,
        chatId,
        topK: limit,
      );

      return jsonEncode(<String, dynamic>{
        'count': results.length,
        'results': [
          for (final r in results)
            <String, dynamic>{
              'source_text': r.record.sourceText,
              'date': r.record.createdAt.split('T').first,
              'score': double.parse(r.score.toStringAsFixed(3)),
              'visibility': r.record.visibility.dbValue,
              'source_type': r.record.sourceType.dbValue,
            },
        ],
      });
    },
  );
}

/// The set of knowledge sources `deep_search` can fan out to.
const _allSources = ['memory', 'outline', 'kan'];

/// Default results per source for deep_search.
const _deepSearchDefaultLimit = 3;

/// Maximum results per source for deep_search.
const _deepSearchMaxLimit = 5;

CustomToolDef _deepSearchTool(
  ToolRegistry registry,
  MemoryRetriever? retriever, {
  String? outlineApiKey,
  String? outlineBaseUrl,
  String? kanApiKey,
  String? kanBaseUrl,
  String? kanWorkspaceId,
  required CliRunner cliRunner,
}) {
  return CustomToolDef(
    name: 'deep_search',
    description: 'Search across all knowledge sources in parallel — long-term '
        'memory, Outline wiki, and Kan task board. Use this for cross-cutting '
        'questions that span multiple domains, or when you are unsure where '
        'the answer lives — including questions about community lore, history, '
        'people, and projects (which live in the Outline wiki). Returns unified '
        'results with source attribution.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'query': <String, dynamic>{
          'type': 'string',
          'description': 'What you are looking for across all sources.',
        },
        'sources': <String, dynamic>{
          'type': 'array',
          'items': <String, dynamic>{
            'type': 'string',
            'enum': ['memory', 'outline', 'kan'],
          },
          'description': 'Which sources to search. Defaults to all available. '
              'Use a subset when you know where the answer lives.',
        },
        'limit': <String, dynamic>{
          'type': 'integer',
          'description': 'Maximum results per source (1–5, default 3).',
        },
      },
      'required': <String>['query'],
    },
    handler: (args) async {
      final query = (args['query'] as String).trim();
      if (query.isEmpty) {
        return jsonEncode(<String, dynamic>{
          'error': 'Query is empty — nothing to search for.',
        });
      }

      final limit = (args['limit'] as int? ?? _deepSearchDefaultLimit)
          .clamp(1, _deepSearchMaxLimit);

      // Determine which sources the caller wants.
      final requestedSources = args['sources'] != null
          ? (args['sources'] as List<dynamic>).cast<String>()
          : List<String>.from(_allSources);

      // A source is available when its backing creds are configured. Outline
      // and Kan are searched via the vendored CLIs (not MCP); Kan's `search`
      // also requires a workspace id, so the Kan arm needs [kanWorkspaceId].
      bool present(String? v) => v != null && v.trim().isNotEmpty;
      final hasMemory = retriever != null;
      final hasOutline = present(outlineApiKey) && present(outlineBaseUrl);
      final hasKan =
          present(kanApiKey) && present(kanBaseUrl) && present(kanWorkspaceId);

      final availability = <String, bool>{
        'memory': hasMemory,
        'outline': hasOutline,
        'kan': hasKan,
      };

      // These lists are mutated inside Future.wait() callbacks below.
      // Safe without synchronization because Dart is single-threaded within
      // an isolate — futures interleave but never run concurrently.
      final sourcesSearched = <String>[];
      final sourcesUnavailable = <String>[];
      final sourcesFailed = <String>[];
      final allResults = <Map<String, dynamic>>[];

      final ctx = registry.context;
      final chatId = ctx?.chatId ?? 'unknown';

      // Build futures for each requested+available source.
      final futures = <Future<void>>[];

      for (final source in requestedSources) {
        if (availability[source] != true) {
          sourcesUnavailable.add(source);
          continue;
        }

        futures.add(_searchSource(
          source: source,
          query: query,
          limit: limit,
          chatId: chatId,
          retriever: retriever,
          cliRunner: cliRunner,
          outlineApiKey: outlineApiKey,
          outlineBaseUrl: outlineBaseUrl,
          kanApiKey: kanApiKey,
          kanBaseUrl: kanBaseUrl,
          kanWorkspaceId: kanWorkspaceId,
        ).then((results) {
          sourcesSearched.add(source);
          allResults.addAll(results);
        }).catchError((Object e) {
          sourcesFailed.add(source);
          developer.log(
            'deep_search: $source failed: $e',
            name: 'MemoryTools',
            level: 900,
          );
        }));
      }

      await Future.wait(futures);

      return jsonEncode(<String, dynamic>{
        'sources_searched': sourcesSearched,
        'sources_unavailable': sourcesUnavailable,
        'sources_failed': sourcesFailed,
        'total_count': allResults.length,
        'results': allResults,
      });
    },
  );
}

/// Searches a single source and returns normalized results.
///
/// The `!` operators are safe because `_deepSearchTool` only invokes this for
/// sources that passed the availability check (retriever != null for memory;
/// the relevant creds present for outline/kan).
Future<List<Map<String, dynamic>>> _searchSource({
  required String source,
  required String query,
  required int limit,
  required String chatId,
  required CliRunner cliRunner,
  MemoryRetriever? retriever,
  String? outlineApiKey,
  String? outlineBaseUrl,
  String? kanApiKey,
  String? kanBaseUrl,
  String? kanWorkspaceId,
}) async {
  switch (source) {
    case 'memory':
      return _searchMemory(retriever!, query, chatId, limit);
    case 'outline':
      return _searchOutline(
        cliRunner,
        query,
        limit,
        outlineApiKey!,
        outlineBaseUrl!,
      );
    case 'kan':
      return _searchKan(
        cliRunner,
        query,
        limit,
        kanApiKey!,
        kanBaseUrl!,
        kanWorkspaceId!,
      );
    default:
      return [];
  }
}

/// Minimal child environment for a vendored-CLI subprocess: `PATH` so `node`
/// resolves, plus the one service's creds. Never leaks DF's other secrets
/// (matches the `run_cli` executor's hardening).
Map<String, String> _cliEnv(Map<String, String> creds) => <String, String>{
      'PATH': Platform.environment['PATH'] ?? '/usr/local/bin:/usr/bin:/bin',
      ...creds,
    };

/// Decodes a vendored-CLI [outcome] to its stdout JSON, throwing on any
/// non-success so `deep_search`'s per-source `catchError` records the failure.
String _cliStdoutOrThrow(String source, CliOutcome outcome) {
  switch (outcome) {
    case CliLaunchFailure(:final message):
      throw Exception('$source CLI launch failed: $message');
    case CliTimeout():
      throw Exception('$source CLI timed out');
    case CliCompleted(:final exitCode, :final stdout, :final stderr):
      if (exitCode != 0) {
        // Include stdout — CLIs often put the useful API error JSON there.
        throw Exception('$source CLI exited $exitCode: '
            '${stderr.isNotEmpty ? stderr : stdout}');
      }
      return stdout;
  }
}

/// Searches local memory embeddings and normalizes results.
Future<List<Map<String, dynamic>>> _searchMemory(
  MemoryRetriever retriever,
  String query,
  String chatId,
  int limit,
) async {
  final results = await retriever.retrieve(query, chatId, topK: limit);
  return [
    for (final r in results)
      <String, dynamic>{
        'source': 'memory',
        'text': r.record.sourceText,
        'date': r.record.createdAt.split('T').first,
        'score': double.parse(r.score.toStringAsFixed(3)),
      },
  ];
}

/// Searches the Outline wiki via the vendored `outline` CLI
/// (`documents.search`) and normalizes results. This is where community lore,
/// history, people, and project docs live.
Future<List<Map<String, dynamic>>> _searchOutline(
  CliRunner cliRunner,
  String query,
  int limit,
  String apiKey,
  String baseUrl,
) async {
  final outcome = await cliRunner(
    tool: 'outline',
    args: <String>['documents.search', '--query', query, '--limit', '$limit'],
    // The outline CLI reads OUTLINE_API_URL, not OUTLINE_BASE_URL.
    env: _cliEnv(<String, String>{
      'OUTLINE_API_KEY': apiKey,
      'OUTLINE_API_URL': baseUrl,
    }),
  );
  final raw = _cliStdoutOrThrow('outline', outcome);

  final parsed = jsonDecode(raw) as Map<String, dynamic>;
  // documents.search returns {data: [{context, document: {...}}]}.
  final data = parsed['data'] as List<dynamic>?;
  if (data == null) {
    developer.log(
      'Outline search returned unexpected format (no "data" key): '
      '${raw.substring(0, raw.length.clamp(0, 200))}',
      name: 'MemoryTools',
      level: 900,
    );
    return [];
  }

  return [
    for (final item in data)
      if (item is Map<String, dynamic>)
        <String, dynamic>{
          'source': 'outline',
          'title': (item['document'] as Map<String, dynamic>?)?['title'] ?? '',
          'text': (item['document'] as Map<String, dynamic>?)?['text'] ?? '',
          'document_id':
              (item['document'] as Map<String, dynamic>?)?['id'] ?? '',
        },
  ];
}

/// Searches the Kan task board via the vendored `kan` CLI (`search`, which
/// requires a workspace id) and normalizes results.
Future<List<Map<String, dynamic>>> _searchKan(
  CliRunner cliRunner,
  String query,
  int limit,
  String apiKey,
  String baseUrl,
  String workspaceId,
) async {
  final outcome = await cliRunner(
    tool: 'kan',
    args: <String>[
      'search',
      '--workspace-id',
      workspaceId,
      '--query',
      query,
      '--limit',
      '$limit',
    ],
    env: _cliEnv(<String, String>{
      'KAN_API_KEY': apiKey,
      'KAN_BASE_URL': baseUrl,
    }),
  );
  final raw = _cliStdoutOrThrow('kan', outcome);

  // The `kan search` CLI prints the raw API response, which is a BARE ARRAY of
  // card hits (verified live) — not a {data: [...]} envelope. Each card carries
  // `publicId`, `title`, `description`, `boardName`, and `listName`.
  final decoded = jsonDecode(raw);
  if (decoded is! List) {
    developer.log(
      'Kan search returned unexpected format (expected a JSON array): '
      '${raw.substring(0, raw.length.clamp(0, 200))}',
      name: 'MemoryTools',
      level: 900,
    );
    return [];
  }

  return [
    for (final item in decoded)
      if (item is Map<String, dynamic>)
        <String, dynamic>{
          'source': 'kan',
          'title': item['title'] ?? '',
          'text': item['description'] ?? '',
          'card_id': item['publicId'] ?? '',
          'list': item['listName'] ?? '',
          'board': item['boardName'] ?? '',
        },
  ];
}
