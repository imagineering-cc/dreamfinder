/// Custom tools for the RAG memory system.
///
/// - `save_memory`: Explicitly save information to long-term memory.
/// - `search_memory`: Actively search past conversations and saved knowledge.
library;

import 'dart:convert';
import 'dart:math' as math;

import '../agent/tool_registry.dart';
import '../memory/embedding_pipeline.dart';
import '../memory/memory_record.dart';
import '../memory/memory_retriever.dart';

/// Registers memory tools with the [ToolRegistry].
///
/// When [pipeline] is `null` (no `VOYAGE_API_KEY`), the save tool is still
/// registered but returns an error when invoked — this lets the agent explain
/// the limitation to the user. Same pattern for [retriever] and search.
void registerMemoryTools(
  ToolRegistry registry,
  EmbeddingPipeline? pipeline,
  MemoryRetriever? retriever,
) {
  registry.registerCustomTool(_saveMemoryTool(registry, pipeline));
  registry.registerCustomTool(_searchMemoryTool(registry, retriever));
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
        senderUuid: ctx?.senderUuid,
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

      final rawLimit = args['limit'] as int? ?? 5;
      final limit = math.min(rawLimit, 10).clamp(1, 10);

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
