/// Game event router — bridges AITW game events to the Dreamfinder agent loop.
///
/// Receives HTTP POST requests from the game client containing chat messages,
/// help requests, and player join/leave events. Dispatches each event to the
/// agent loop with `chatId = 'game:$roomName'` and sends responses back to the
/// game via LiveKit data channels.
///
/// This is the core of the HTTP bridge: HTTP in, LiveKit out.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../agent/agent_loop.dart';
import '../agent/tool_registry.dart';
import '../livekit/livekit_server_client.dart';
import '../logging/logger.dart';
import '../session/session.dart';
import '../session/session_state.dart';
import '../session/session_timer.dart';

/// Callback that builds a system prompt for a game message.
///
/// Captures all the dependencies (env, queries, memory, etc.) from the
/// main closure so the router doesn't need to know about them.
typedef BuildSystemPrompt = String Function({
  required AgentInput input,
  required String chatId,
  required String senderId,
  required bool isGroup,
});

/// Routes game events from the HTTP bridge to the agent loop.
///
/// The game client POSTs events to `/api/game/event`. This router parses
/// them, builds an [AgentInput], runs it through the agent loop, and sends
/// the response back via LiveKit data channels.
class GameEventRouter {
  GameEventRouter({
    required this.agentLoop,
    required this.toolRegistry,
    required this.liveKitClient,
    required this.sessionState,
    required this.sessionTimer,
    required this.buildSystemPrompt,
    required this.log,
    this.botName = 'Dreamfinder',
  });

  final AgentLoop agentLoop;
  final ToolRegistry toolRegistry;
  final LiveKitServerClient liveKitClient;
  final SessionState sessionState;
  final SessionTimer sessionTimer;
  final BuildSystemPrompt buildSystemPrompt;
  final BotLogger log;
  final String botName;

  /// Handles an HTTP request containing a game event.
  ///
  /// Returns 202 Accepted immediately, then processes the event async.
  /// The AI response is sent back via LiveKit data channels.
  Future<void> handleRequest(HttpRequest request) async {
    // Parse the request body.
    final String body;
    try {
      body = await utf8.decoder.bind(request).join();
    } on Exception {
      _jsonResponse(request, HttpStatus.badRequest, {
        'error': 'Could not read request body',
      });
      return;
    }

    final Map<String, dynamic> event;
    try {
      event = jsonDecode(body) as Map<String, dynamic>;
    } on FormatException {
      _jsonResponse(request, HttpStatus.badRequest, {
        'error': 'Invalid JSON',
      });
      return;
    }

    // Validate required fields.
    final topic = event['topic'] as String?;
    final roomName = event['roomName'] as String?;
    final senderId = event['senderId'] as String?;
    final senderName = event['senderName'] as String?;
    final payload = event['payload'] as Map<String, dynamic>?;

    if (topic == null || roomName == null || senderId == null) {
      _jsonResponse(request, HttpStatus.badRequest, {
        'error': 'Missing required fields: topic, roomName, senderId',
      });
      return;
    }

    // Return 202 immediately — fire-and-forget from the client's perspective.
    _jsonResponse(request, HttpStatus.accepted, {'ok': true});

    // Process the event async.
    final chatId = 'game:$roomName';

    log.info('Game event received', extra: {
      'topic': topic,
      'room': roomName,
      'sender': senderId,
    });

    try {
      switch (topic) {
        case 'chat':
          await _handleChat(
            chatId: chatId,
            roomName: roomName,
            senderId: senderId,
            senderName: senderName,
            payload: payload ?? const {},
          );
        case 'help-request':
          await _handleHelpRequest(
            chatId: chatId,
            roomName: roomName,
            senderId: senderId,
            senderName: senderName,
            payload: payload ?? const {},
          );
        case 'player-join':
          await _handlePlayerJoin(
            chatId: chatId,
            roomName: roomName,
            senderId: senderId,
            senderName: senderName,
          );
        case 'player-leave':
          log.info('Player left', extra: {
            'room': roomName,
            'player': senderName ?? senderId,
          });
        default:
          log.warning('Unknown game event topic: $topic');
      }
    } on Exception catch (e) {
      log.error('Error processing game event', extra: {
        'error': e.toString(),
      });
    }
  }

  /// Handles a chat message from the game.
  ///
  /// Checks for session triggers, builds the system prompt (with session
  /// phase injection if active), processes through the agent loop, and
  /// sends the response back via LiveKit.
  Future<void> _handleChat({
    required String chatId,
    required String roomName,
    required String senderId,
    required String? senderName,
    required Map<String, dynamic> payload,
  }) async {
    final text = payload['text'] as String?;
    if (text == null || text.trim().isEmpty) return;

    // Detect session triggers.
    if (isSessionMessage(text) && !sessionState.isSessionActive(chatId)) {
      sessionState.startSession(chatId, initiatorId: senderId);
      sessionTimer.startTimer(chatId, SessionPhase.pitch);
      log.info('Session started via game', extra: {
        'room': roomName,
        'sender': senderId,
      });
    }

    // Add participant to active session.
    if (sessionState.isSessionActive(chatId)) {
      sessionState.addParticipant(chatId, senderId);
    }

    final input = AgentInput(
      text: text,
      chatId: chatId,
      senderId: senderId,
      senderName: senderName,
      isAdmin: false,
      isGroup: true,
    );

    toolRegistry.setContext(ToolContext(
      senderId: senderId,
      isAdmin: false,
      chatId: chatId,
      isGroup: true,
    ));

    final systemPrompt = buildSystemPrompt(
      input: input,
      chatId: chatId,
      senderId: senderId,
      isGroup: true,
    );

    final response = await agentLoop.processMessage(
      input,
      systemPrompt: systemPrompt,
    );

    await _sendChatResponse(roomName, response, payload['id'] as String?);
  }

  /// Handles a help request from the game.
  Future<void> _handleHelpRequest({
    required String chatId,
    required String roomName,
    required String senderId,
    required String? senderName,
    required Map<String, dynamic> payload,
  }) async {
    final code = payload['code'] as String? ?? '';
    final challengeId = payload['challengeId'] as String? ?? 'unknown';
    final text =
        'I need help with challenge "$challengeId". Here is my code:\n\n'
        '```\n$code\n```';

    final input = AgentInput(
      text: text,
      chatId: chatId,
      senderId: senderId,
      senderName: senderName,
      isAdmin: false,
      isGroup: false, // Help requests are 1:1.
    );

    toolRegistry.setContext(ToolContext(
      senderId: senderId,
      isAdmin: false,
      chatId: chatId,
      isGroup: false,
    ));

    final systemPrompt = buildSystemPrompt(
      input: input,
      chatId: chatId,
      senderId: senderId,
      isGroup: false,
    );

    final response = await agentLoop.processMessage(
      input,
      systemPrompt: systemPrompt,
    );

    await liveKitClient.sendJson(
      room: roomName,
      topic: 'help-response',
      payload: <String, Object?>{
        'text': response,
        'senderName': botName,
        'senderId': 'bot-dreamfinder',
        'messageId': payload['id'] as String?,
        'id': 'resp-${DateTime.now().millisecondsSinceEpoch}',
      },
      destinationIdentities: [senderId],
    );
  }

  /// Handles a player joining the game.
  ///
  /// If a session is active, adds the player as a participant and sends
  /// a contextual greeting. Otherwise, sends a simple welcome.
  Future<void> _handlePlayerJoin({
    required String chatId,
    required String roomName,
    required String senderId,
    required String? senderName,
  }) async {
    log.info('Player joined', extra: {
      'room': roomName,
      'player': senderName ?? senderId,
    });

    // Add to session if one is active.
    if (sessionState.isSessionActive(chatId)) {
      sessionState.addParticipant(chatId, senderId);
    }

    // Generate a welcome via the agent loop.
    final name = senderName ?? 'there';
    final input = AgentInput(
      text: '$name just joined the game.',
      chatId: chatId,
      senderId: 'system',
      isAdmin: true,
      isGroup: true,
      isSystemInitiated: true,
    );

    final systemPrompt = buildSystemPrompt(
      input: input,
      chatId: chatId,
      senderId: 'system',
      isGroup: true,
    );

    final response = await agentLoop.processMessage(
      input,
      systemPrompt: systemPrompt,
    );

    await _sendChatResponse(roomName, response, null);
  }

  /// Sends a chat response back to the game via LiveKit.
  Future<void> _sendChatResponse(
    String roomName,
    String text,
    String? correlationId,
  ) async {
    await liveKitClient.sendJson(
      room: roomName,
      topic: 'chat-response',
      payload: <String, Object?>{
        'text': text,
        'senderName': botName,
        'senderId': 'bot-dreamfinder',
        if (correlationId != null) 'messageId': correlationId,
        'id': 'resp-${DateTime.now().millisecondsSinceEpoch}',
      },
    );
  }

  /// Writes a JSON response and closes the request.
  void _jsonResponse(
    HttpRequest request,
    int statusCode,
    Map<String, Object?> body,
  ) {
    request.response
      ..statusCode = statusCode
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body))
      ..close();
  }
}
