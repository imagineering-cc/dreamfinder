/// Custom tool for explicit memory saves via natural language.
///
/// The `save_memory` tool lets the agent store a piece of knowledge in the
/// RAG memory system with an explicit visibility level, overriding the
/// automatic chat-context-based default. Any user can ask the bot to
/// "remember this everywhere" (or similar), and the agent calls this tool.
library;

import 'dart:convert';

import '../agent/tool_registry.dart';
import '../memory/embedding_pipeline.dart';
import '../memory/memory_record.dart';

/// Registers memory tools with the [ToolRegistry].
///
/// When [pipeline] is `null` (no `VOYAGE_API_KEY`), the tool is still
/// registered but returns an error when invoked — this lets the agent
/// explain the limitation to the user.
void registerMemoryTools(ToolRegistry registry, EmbeddingPipeline? pipeline) {
  registry.registerCustomTool(_saveMemoryTool(registry, pipeline));
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
