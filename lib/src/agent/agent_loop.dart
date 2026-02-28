import 'dart:developer' as developer;

import 'conversation_history.dart';
import 'tool_registry.dart';

/// Why the model stopped generating.
enum StopReason { endTurn, toolUse, maxTokens }

/// A text block in a Claude response.
class TextContent {
  const TextContent({required this.text});
  final String text;
}

/// A tool-use block in a Claude response.
class ToolUseContent {
  const ToolUseContent({
    required this.id,
    required this.name,
    required this.input,
  });

  final String id;
  final String name;
  final Map<String, dynamic> input;
}

/// The result of feeding a tool's output back to Claude.
class ToolResultMessage {
  const ToolResultMessage({
    required this.toolUseId,
    required this.content,
    this.isError = false,
  });

  final String toolUseId;
  final String content;
  final bool isError;
}

/// Simplified Claude API response used by the agent loop.
class AgentResponse {
  const AgentResponse({
    required this.textBlocks,
    required this.toolUseBlocks,
    required this.stopReason,
  });

  final List<TextContent> textBlocks;
  final List<ToolUseContent> toolUseBlocks;
  final StopReason stopReason;
}

/// A message in the agent loop's running conversation.
class AgentMessage {
  const AgentMessage({required this.role, required this.content});

  final String role;
  final dynamic content;
}

/// Input context for processing a single user message.
class AgentInput {
  const AgentInput({
    required this.text,
    required this.chatId,
    required this.senderUuid,
    this.senderName,
    required this.isAdmin,
    this.replyToText,
    this.replyToName,
  });

  final String text;
  final String chatId;
  final String senderUuid;
  final String? senderName;
  final bool isAdmin;
  final String? replyToText;
  final String? replyToName;
}

/// Signature for the Claude API call, decoupled from the SDK.
typedef CreateMessageFn = Future<AgentResponse> Function(
  List<AgentMessage> messages,
  List<ToolDefinition> tools,
  String systemPrompt,
);

/// Optional callback for typing indicators.
typedef TypingIndicatorFn = Future<void> Function(String chatId);

const _defaultMaxToolRounds = 10;
const _fallbackMessage = 'I ran into too many steps trying to complete that. '
    'Could you try a simpler request?';

/// The core agent loop: sends messages to Claude, executes tool calls,
/// and iterates until a final text response (or max rounds exhausted).
class AgentLoop {
  AgentLoop({
    required CreateMessageFn createMessage,
    required ToolRegistry toolRegistry,
    required ConversationHistory history,
    int maxToolRounds = _defaultMaxToolRounds,
    TypingIndicatorFn? onTyping,
  })  : _createMessage = createMessage,
        _toolRegistry = toolRegistry,
        _history = history,
        _maxToolRounds = maxToolRounds,
        _onTyping = onTyping;

  final CreateMessageFn _createMessage;
  final ToolRegistry _toolRegistry;
  final ConversationHistory _history;
  final int _maxToolRounds;
  final TypingIndicatorFn? _onTyping;

  /// Processes a user message through the full agent loop.
  Future<String> processMessage(
    AgentInput input, {
    required String systemPrompt,
  }) async {
    final tools = _toolRegistry.getAllToolDefinitions();
    final historyMsgs = _history.getHistory(input.chatId);
    final messages = <AgentMessage>[
      for (final msg in historyMsgs)
        AgentMessage(
          role: msg.role == MessageRole.user ? 'user' : 'assistant',
          content: msg.content,
        ),
      AgentMessage(role: 'user', content: input.text),
    ];

    _sendTyping(input.chatId);

    AgentResponse? lastResponse;
    var rounds = 0;

    while (rounds < _maxToolRounds) {
      rounds++;
      lastResponse = await _createMessage(messages, tools, systemPrompt);

      final toolUses = lastResponse.toolUseBlocks;
      if (toolUses.isEmpty) {
        final text = _extractText(lastResponse);
        _history.appendToHistory(
          input.chatId,
          ChatMessage(role: MessageRole.user, content: input.text),
          ChatMessage(role: MessageRole.assistant, content: text),
        );
        return text;
      }

      messages.add(AgentMessage(
        role: 'assistant',
        content: <String, dynamic>{
          'textBlocks': <Map<String, String>>[
            for (final t in lastResponse.textBlocks)
              <String, String>{'text': t.text},
          ],
          'toolUseBlocks': <Map<String, dynamic>>[
            for (final t in toolUses)
              <String, dynamic>{
                'id': t.id,
                'name': t.name,
                'input': t.input,
              },
          ],
        },
      ));

      final toolResults = <ToolResultMessage>[];
      for (final toolUse in toolUses) {
        _sendTyping(input.chatId);
        String result;
        var isError = false;
        try {
          developer.log(
            'Tool call: ${toolUse.name}(${toolUse.input})',
            name: 'AgentLoop',
          );
          result = await _toolRegistry.executeTool(toolUse.name, toolUse.input);
        } on Exception catch (e) {
          result = 'Error: $e';
          isError = true;
          developer.log(
            'Tool ${toolUse.name} failed: $e',
            name: 'AgentLoop',
            level: 900,
          );
        }
        toolResults.add(ToolResultMessage(
          toolUseId: toolUse.id,
          content: result,
          isError: isError,
        ));
      }

      messages.add(AgentMessage(
        role: 'tool_result',
        content: <Map<String, dynamic>>[
          for (final r in toolResults)
            <String, dynamic>{
              'toolUseId': r.toolUseId,
              'content': r.content,
              'isError': r.isError,
            },
        ],
      ));
    }

    final fallbackText =
        lastResponse != null ? _extractText(lastResponse) : _fallbackMessage;

    _history.appendToHistory(
      input.chatId,
      ChatMessage(role: MessageRole.user, content: input.text),
      ChatMessage(
        role: MessageRole.assistant,
        content: fallbackText.isNotEmpty ? fallbackText : _fallbackMessage,
      ),
    );

    return fallbackText.isNotEmpty ? fallbackText : _fallbackMessage;
  }

  String _extractText(AgentResponse response) {
    return response.textBlocks.map((b) => b.text).join('\n').trim();
  }

  void _sendTyping(String chatId) {
    _onTyping?.call(chatId).ignore();
  }
}
