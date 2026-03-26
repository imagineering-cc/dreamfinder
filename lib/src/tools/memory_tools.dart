/// Custom tools for the RAG memory system.
///
/// - `save_memory`: Explicitly save information to long-term memory.
/// - `search_memory`: Actively search past conversations and saved knowledge.
/// - `deep_search`: Parallel multi-source search across memory, Outline, and
///   Kan — the agentic RAG tool for cross-cutting questions.
library;

import 'dart:convert';
import 'dart:developer' as developer;

import '../agent/tool_registry.dart';
import '../mcp/mcp_manager.dart';
import '../memory/embedding_pipeline.dart';
import '../memory/memory_record.dart';
import '../memory/memory_retriever.dart';

/// Registers memory tools with the [ToolRegistry].
///
/// When [pipeline] is `null` (no `VOYAGE_API_KEY`), the save tool is still
/// registered but returns an error when invoked — this lets the agent explain
/// the limitation to the user. Same pattern for [retriever] and search.
///
/// When [mcpManager] is provided, `deep_search` can fan out to Outline and Kan
/// MCP servers in parallel alongside local memory retrieval.
void registerMemoryTools(
  ToolRegistry registry,
  EmbeddingPipeline? pipeline,
  MemoryRetriever? retriever, [
  McpManager? mcpManager,
]) {
  registry.registerCustomTool(_saveMemoryTool(registry, pipeline));
  registry.registerCustomTool(_searchMemoryTool(registry, retriever));
  registry.registerCustomTool(
    _deepSearchTool(registry, retriever, mcpManager),
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
          'description':
              'The search query — a natural language description of '
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
  MemoryRetriever? retriever,
  McpManager? mcpManager,
) {
  return CustomToolDef(
    name: 'deep_search',
    description: 'Search across all knowledge sources in parallel — long-term '
        'memory, Outline wiki, and Kan task board. Use this for cross-cutting '
        'questions that span multiple domains, or when you are unsure where '
        'the answer lives. Returns unified results with source attribution.',
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
          'description':
              'Maximum results per source (1–5, default 3).',
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

      // Detect which MCP tools are actually available.
      final mcpToolNames = mcpManager
              ?.getAllTools()
              .map((t) => t.name)
              .toSet() ??
          <String>{};

      final hasMemory = retriever != null;
      final hasOutline = mcpToolNames.contains('outline_search');
      final hasKan = mcpToolNames.contains('kan_search');

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
          mcpManager: mcpManager,
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
/// The `!` operators on [retriever] and [mcpManager] are safe because the
/// caller in `_deepSearchTool` only invokes this for sources that passed the
/// availability check (retriever != null for memory, mcpManager has the
/// required tool for outline/kan).
Future<List<Map<String, dynamic>>> _searchSource({
  required String source,
  required String query,
  required int limit,
  required String chatId,
  MemoryRetriever? retriever,
  McpManager? mcpManager,
}) async {
  switch (source) {
    case 'memory':
      return _searchMemory(retriever!, query, chatId, limit);
    case 'outline':
      return _searchOutline(mcpManager!, query, limit);
    case 'kan':
      return _searchKan(mcpManager!, query, limit);
    default:
      return [];
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

/// Searches Outline wiki via MCP and normalizes results.
Future<List<Map<String, dynamic>>> _searchOutline(
  McpManager mcpManager,
  String query,
  int limit,
) async {
  final raw = await mcpManager.callTool('outline_search', <String, dynamic>{
    'query': query,
    'limit': limit,
  });
  final parsed = jsonDecode(raw) as Map<String, dynamic>;
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

/// Searches Kan task board via MCP and normalizes results.
Future<List<Map<String, dynamic>>> _searchKan(
  McpManager mcpManager,
  String query,
  int limit,
) async {
  final raw = await mcpManager.callTool('kan_search', <String, dynamic>{
    'query': query,
    'limit': limit,
  });
  final parsed = jsonDecode(raw) as Map<String, dynamic>;
  final data = parsed['data'] as List<dynamic>?;
  if (data == null) {
    developer.log(
      'Kan search returned unexpected format (no "data" key): '
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
          'source': 'kan',
          'title': item['title'] ?? '',
          'text': item['description'] ?? '',
          'card_id': item['id'] ?? '',
          'list': (item['list'] as Map<String, dynamic>?)?['name'] ?? '',
        },
  ];
}
