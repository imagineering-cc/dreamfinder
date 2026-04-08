import 'dart:convert';
import 'dart:io';

import 'package:dreamfinder/src/agent/agent_loop.dart';
import 'package:dreamfinder/src/agent/tool_registry.dart';
import 'package:dreamfinder/src/bot/health_check.dart';
import 'package:dreamfinder/src/db/database.dart';
import 'package:dreamfinder/src/db/queries.dart';
import 'package:dreamfinder/src/game/game_event_router.dart';
import 'package:dreamfinder/src/livekit/livekit_server_client.dart';
import 'package:dreamfinder/src/logging/logger.dart';
import 'package:dreamfinder/src/session/session_state.dart';
import 'package:dreamfinder/src/session/session_timer.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

class MockAgentLoop extends Mock implements AgentLoop {}

class MockLiveKitServerClient extends Mock implements LiveKitServerClient {}

void main() {
  late BotDatabase db;
  late Queries queries;
  late SessionState sessionState;
  late SessionTimer sessionTimer;
  late MockAgentLoop agentLoop;
  late MockLiveKitServerClient liveKitClient;
  late ToolRegistry toolRegistry;
  late GameEventRouter router;
  late HealthCheck health;
  late HttpClient httpClient;
  late int port;

  setUpAll(() {
    registerFallbackValue(AgentInput(
      text: '',
      chatId: '',
      senderId: '',
      isAdmin: false,
    ));
    registerFallbackValue(const ToolContext(
      senderId: '',
      isAdmin: false,
      chatId: '',
      isGroup: false,
    ));
  });

  setUp(() async {
    db = BotDatabase.inMemory();
    queries = Queries(db);
    sessionState = SessionState(queries: queries);
    agentLoop = MockAgentLoop();
    liveKitClient = MockLiveKitServerClient();
    toolRegistry = ToolRegistry();

    sessionTimer = SessionTimer(
      sessionState: sessionState,
      onPhaseTransition: (_, __) async {},
    );

    router = GameEventRouter(
      agentLoop: agentLoop,
      toolRegistry: toolRegistry,
      liveKitClient: liveKitClient,
      sessionState: sessionState,
      sessionTimer: sessionTimer,
      botName: 'Dreamfinder',
      log: BotLogger(name: 'Test', level: LogLevel.error),
      buildSystemPrompt: ({
        required input,
        required chatId,
        required senderId,
        required isGroup,
      }) =>
          'test system prompt',
    );

    // Set up HealthCheck with the router.
    health = HealthCheck();
    health.apiKey = 'test-key';
    health.onGameEvent = router.handleRequest;
    port = await health.start(port: 0); // Random available port.
    httpClient = HttpClient();
  });

  tearDown(() async {
    httpClient.close();
    health.stop();
    db.close();
  });

  /// Helper to POST a game event to the local health check server.
  Future<HttpClientResponse> postEvent(
    Map<String, dynamic> body, {
    String? apiKey,
  }) async {
    final request = await httpClient.postUrl(
      Uri.parse('http://localhost:$port/api/game/event'),
    );
    request.headers.set('Content-Type', 'application/json');
    request.headers.set('Authorization', 'Bearer ${apiKey ?? 'test-key'}');
    request.write(jsonEncode(body));
    return request.close();
  }

  group('HTTP layer', () {
    test('returns 202 Accepted for valid event', () async {
      when(() => agentLoop.processMessage(
            any(),
            systemPrompt: any(named: 'systemPrompt'),
          )).thenAnswer((_) async => 'Hello!');
      when(() => liveKitClient.sendJson(
            room: any(named: 'room'),
            topic: any(named: 'topic'),
            payload: any(named: 'payload'),
          )).thenAnswer((_) async {});

      final response = await postEvent({
        'topic': 'chat',
        'roomName': 'tech-world',
        'senderId': 'user-1',
        'senderName': 'Alice',
        'payload': {'text': 'hello', 'id': '123'},
      });

      expect(response.statusCode, HttpStatus.accepted);
    });

    test('returns 401 for missing auth', () async {
      final response = await postEvent(
        {
          'topic': 'chat',
          'roomName': 'tech-world',
          'senderId': 'user-1',
        },
        apiKey: 'wrong-key',
      );

      expect(response.statusCode, HttpStatus.unauthorized);
    });

    test('returns 400 for missing required fields', () async {
      final response = await postEvent({
        'topic': 'chat',
        // Missing roomName and senderId.
      });

      expect(response.statusCode, HttpStatus.badRequest);
    });

    test('returns 400 for invalid JSON', () async {
      final request = await httpClient.postUrl(
        Uri.parse('http://localhost:$port/api/game/event'),
      );
      request.headers.set('Content-Type', 'application/json');
      request.headers.set('Authorization', 'Bearer test-key');
      request.write('not json at all');
      final response = await request.close();

      expect(response.statusCode, HttpStatus.badRequest);
    });

    test('includes CORS headers', () async {
      when(() => agentLoop.processMessage(
            any(),
            systemPrompt: any(named: 'systemPrompt'),
          )).thenAnswer((_) async => 'Hello!');
      when(() => liveKitClient.sendJson(
            room: any(named: 'room'),
            topic: any(named: 'topic'),
            payload: any(named: 'payload'),
          )).thenAnswer((_) async {});

      final response = await postEvent({
        'topic': 'chat',
        'roomName': 'tech-world',
        'senderId': 'user-1',
        'payload': {'text': 'hi', 'id': '1'},
      });

      expect(
        response.headers.value('access-control-allow-origin'),
        equals('*'),
      );
    });

    test('OPTIONS preflight returns 204', () async {
      final request = await httpClient.openUrl(
        'OPTIONS',
        Uri.parse('http://localhost:$port/api/game/event'),
      );
      final response = await request.close();

      expect(response.statusCode, HttpStatus.noContent);
    });
  });

  group('chat routing', () {
    test('forwards chat to agent loop and responds via LiveKit', () async {
      when(() => agentLoop.processMessage(
            any(),
            systemPrompt: any(named: 'systemPrompt'),
          )).thenAnswer((_) async => 'Hi Alice!');
      when(() => liveKitClient.sendJson(
            room: any(named: 'room'),
            topic: any(named: 'topic'),
            payload: any(named: 'payload'),
          )).thenAnswer((_) async {});

      await postEvent({
        'topic': 'chat',
        'roomName': 'tech-world',
        'senderId': 'user-1',
        'senderName': 'Alice',
        'payload': {'text': 'hello there', 'id': '456'},
      });

      // Wait for async processing.
      await Future<void>.delayed(const Duration(milliseconds: 500));

      // Verify agent loop was called with correct chatId.
      final captured = verify(() => agentLoop.processMessage(
            captureAny(),
            systemPrompt: any(named: 'systemPrompt'),
          )).captured;
      final input = captured.first as AgentInput;
      expect(input.chatId, 'game:tech-world');
      expect(input.senderId, 'user-1');
      expect(input.text, 'hello there');
      expect(input.isGroup, isTrue);

      // Verify LiveKit response was sent.
      verify(() => liveKitClient.sendJson(
            room: 'tech-world',
            topic: 'chat-response',
            payload: any(named: 'payload'),
          )).called(1);
    });
  });

  group('session detection', () {
    test('starts session on trigger phrase', () async {
      when(() => agentLoop.processMessage(
            any(),
            systemPrompt: any(named: 'systemPrompt'),
          )).thenAnswer((_) async => 'Session starting!');
      when(() => liveKitClient.sendJson(
            room: any(named: 'room'),
            topic: any(named: 'topic'),
            payload: any(named: 'payload'),
          )).thenAnswer((_) async {});

      await postEvent({
        'topic': 'chat',
        'roomName': 'tech-world',
        'senderId': 'user-1',
        'senderName': 'Alice',
        'payload': {'text': 'session time!', 'id': '789'},
      });

      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(
        sessionState.getActiveSession('game:tech-world'),
        SessionPhase.pitch,
      );
      expect(sessionTimer.hasTimer('game:tech-world'), isTrue);
    });

    test('adds participant to active session', () async {
      // Start a session first.
      sessionState.startSession('game:tech-world', initiatorId: 'user-1');

      when(() => agentLoop.processMessage(
            any(),
            systemPrompt: any(named: 'systemPrompt'),
          )).thenAnswer((_) async => 'Welcome!');
      when(() => liveKitClient.sendJson(
            room: any(named: 'room'),
            topic: any(named: 'topic'),
            payload: any(named: 'payload'),
          )).thenAnswer((_) async {});

      await postEvent({
        'topic': 'chat',
        'roomName': 'tech-world',
        'senderId': 'user-2',
        'senderName': 'Bob',
        'payload': {'text': 'hey everyone', 'id': '101'},
      });

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final participants =
          sessionState.getParticipants('game:tech-world');
      expect(participants, contains('user-2'));
    });
  });

  group('unknown topics', () {
    test('returns 202 but does not call agent loop', () async {
      final response = await postEvent({
        'topic': 'unknown-topic',
        'roomName': 'tech-world',
        'senderId': 'user-1',
      });

      expect(response.statusCode, HttpStatus.accepted);

      await Future<void>.delayed(const Duration(milliseconds: 200));

      verifyNever(() => agentLoop.processMessage(
            any(),
            systemPrompt: any(named: 'systemPrompt'),
          ));
    });
  });
}
