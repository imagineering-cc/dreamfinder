import 'dart:developer' as developer;

import '../memory/embedding_pipeline.dart';
import '../memory/memory_record.dart';
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
    this.inputTokens = 0,
    this.outputTokens = 0,
  });

  final List<TextContent> textBlocks;
  final List<ToolUseContent> toolUseBlocks;
  final StopReason stopReason;

  /// Token usage from this API call.
  final int inputTokens;
  final int outputTokens;
}

/// Accumulated token usage across an agent loop run.
class TokenUsage {
  int inputTokens = 0;
  int outputTokens = 0;

  /// Total tokens (input + output).
  int get totalTokens => inputTokens + outputTokens;

  void add(AgentResponse response) {
    inputTokens += response.inputTokens;
    outputTokens += response.outputTokens;
  }

  @override
  String toString() =>
      'TokenUsage(input: $inputTokens, output: $outputTokens, '
      'total: $totalTokens)';
}

/// Result of processing a message through the agent loop.
class AgentResult {
  const AgentResult({
    required this.text,
    required this.usage,
    required this.toolCallCount,
  });

  /// The final text response.
  final String text;

  /// Accumulated token usage across all rounds.
  final TokenUsage usage;

  /// Number of tool calls made during processing.
  final int toolCallCount;
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
    this.isGroup = false,
    this.replyToText,
    this.replyToName,
    this.isSystemInitiated = false,
  });

  final String text;
  final String chatId;
  final String senderUuid;
  final String? senderName;
  final bool isAdmin;

  /// Whether this message originates from a group chat (vs a 1:1 DM).
  ///
  /// Used to derive automatic memory visibility:
  /// - Group → `sameChat`, 1:1 admin → `crossChat`, 1:1 non-admin → `private`.
  final bool isGroup;

  final String? replyToText;
  final String? replyToName;

  /// When true, this message originates from the scheduler (not a user).
  ///
  /// System-initiated messages bypass tools (empty tool list) for a fast
  /// single-round response, and receive a tailored system prompt section.
  final bool isSystemInitiated;
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
///
/// Full turns (including intermediate tool_use / tool_result pairs) are
/// persisted to [ConversationHistory] so follow-up requests retain tool
/// context.
class AgentLoop {
  AgentLoop({
    required CreateMessageFn createMessage,
    required ToolRegistry toolRegistry,
    required ConversationHistory history,
    int maxToolRounds = _defaultMaxToolRounds,
    TypingIndicatorFn? onTyping,
    EmbeddingPipeline? embeddingPipeline,
  })  : _createMessage = createMessage,
        _toolRegistry = toolRegistry,
        _history = history,
        _maxToolRounds = maxToolRounds,
        _onTyping = onTyping,
        _embeddingPipeline = embeddingPipeline;

  final CreateMessageFn _createMessage;
  final ToolRegistry _toolRegistry;
  final ConversationHistory _history;
  final int _maxToolRounds;
  final TypingIndicatorFn? _onTyping;
  final EmbeddingPipeline? _embeddingPipeline;

  /// Processes a user message through the full agent loop.
  ///
  /// When [maxToolRounds] is provided, it overrides the constructor default.
  /// The dream cycle uses this to allow up to 50 tool rounds.
  Future<String> processMessage(
    AgentInput input, {
    required String systemPrompt,
    int? maxToolRounds,
  }) async {
    final result = await processMessageWithUsage(
      input,
      systemPrompt: systemPrompt,
      maxToolRounds: maxToolRounds,
    );
    return result.text;
  }

  /// Like [processMessage], but also returns token usage and tool call count.
  ///
  /// Used by the dream cycle to track total cost across multiple cycles.
  Future<AgentResult> processMessageWithUsage(
    AgentInput input, {
    required String systemPrompt,
    int? maxToolRounds,
  }) async {
    final tools = input.isSystemInitiated
        ? <ToolDefinition>[]
        : _toolRegistry.getAllToolDefinitions();
    final historyMsgs = _history.getHistory(input.chatId);
    final messages = <AgentMessage>[
      for (final msg in historyMsgs) _historyToAgentMessage(msg),
      AgentMessage(role: 'user', content: input.text),
    ];

    // Index of the new user message — everything from here onwards is the
    // current turn that we'll persist.
    final turnStartIndex = messages.length - 1;

    _sendTyping(input.chatId);

    final effectiveMaxRounds = maxToolRounds ?? _maxToolRounds;
    final usage = TokenUsage();
    var toolCallCount = 0;

    AgentResponse? lastResponse;
    var rounds = 0;

    while (rounds < effectiveMaxRounds) {
      rounds++;
      lastResponse = await _createMessage(messages, tools, systemPrompt);
      usage.add(lastResponse);

      final toolUses = lastResponse.toolUseBlocks;
      if (toolUses.isEmpty) {
        final text = _extractText(lastResponse);
        messages.add(AgentMessage(role: 'assistant', content: text));

        _persistTurn(input.chatId, messages, turnStartIndex);
        _queueEmbedding(input, text);
        return AgentResult(
          text: text,
          usage: usage,
          toolCallCount: toolCallCount,
        );
      }

      toolCallCount += toolUses.length;

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

    // Max rounds exceeded — persist whatever we have plus a fallback response.
    final fallbackText =
        lastResponse != null ? _extractText(lastResponse) : _fallbackMessage;
    final responseText =
        fallbackText.isNotEmpty ? fallbackText : _fallbackMessage;

    messages.add(AgentMessage(role: 'assistant', content: responseText));
    _persistTurn(input.chatId, messages, turnStartIndex);
    _queueEmbedding(input, responseText);

    return AgentResult(
      text: responseText,
      usage: usage,
      toolCallCount: toolCallCount,
    );
  }

  /// Extracts the turn slice from [messages] and persists it to history.
  void _persistTurn(
    String chatId,
    List<AgentMessage> messages,
    int turnStartIndex,
  ) {
    final turnMessages =
        messages.sublist(turnStartIndex).map(_toHistoryMessage).toList();
    _history.appendTurn(chatId, turnMessages);
  }

  /// Converts a [ChatMessage] from history into an [AgentMessage] with the
  /// correct role.
  ///
  /// Tool-result blocks are stored with [MessageRole.user] in the DB
  /// (matching the Anthropic API), but carry [List] content. This method
  /// restores the `tool_result` role so [_callClaude] routes them correctly.
  AgentMessage _historyToAgentMessage(ChatMessage msg) {
    if (msg.role == MessageRole.user && msg.content is List) {
      return AgentMessage(role: 'tool_result', content: msg.content);
    }
    return AgentMessage(
      role: msg.role == MessageRole.user ? 'user' : 'assistant',
      content: msg.content,
    );
  }

  /// Converts an [AgentMessage] to a [ChatMessage] for history storage.
  ///
  /// The `tool_result` role collapses to [MessageRole.user] — the structured
  /// [List] content distinguishes it from plain text user messages.
  ChatMessage _toHistoryMessage(AgentMessage msg) {
    if (msg.role == 'tool_result') {
      return ChatMessage(role: MessageRole.user, content: msg.content as Object);
    }
    return ChatMessage(
      role: msg.role == 'user' ? MessageRole.user : MessageRole.assistant,
      content: msg.content as Object,
    );
  }

  String _extractText(AgentResponse response) {
    return response.textBlocks.map((b) => b.text).join('\n').trim();
  }

  /// Queues the user+assistant turn for background embedding.
  ///
  /// Skips system-initiated messages (standup prompts, deploy announcements)
  /// since they're operational rather than semantic.
  void _queueEmbedding(AgentInput input, String assistantText) {
    if (_embeddingPipeline == null || input.isSystemInitiated) return;
    final visibility = input.isGroup
        ? MemoryVisibility.sameChat
        : input.isAdmin
            ? MemoryVisibility.crossChat
            : MemoryVisibility.private_;
    _embeddingPipeline.queue(
      chatId: input.chatId,
      userText: input.text,
      assistantText: assistantText,
      senderUuid: input.senderUuid,
      senderName: input.senderName,
      visibility: visibility,
    );
  }

  void _sendTyping(String chatId) {
    _onTyping?.call(chatId).ignore();
  }
}
