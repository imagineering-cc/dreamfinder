/// HTTP health check and API server.
///
/// Reports uptime, last poll time, last successful Claude API call, and
/// cumulative error count. Designed for Docker `healthcheck:` directives
/// and GCP load balancer health probes.
///
/// Also serves memory search and save endpoints for the embodied avatar
/// frontend, bridging the text bot's memory system to the voice brain.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../memory/embedding_pipeline.dart';
import '../memory/memory_record.dart';
import '../memory/memory_retriever.dart';

/// HTTP health check and API server.
///
/// Call [recordPoll], [recordClaudeSuccess], and [recordError] from the
/// main event loop to keep the health status current.
/// Default threshold: if no poll for 2 minutes, report degraded.
const _defaultStalePollThreshold = Duration(minutes: 2);

class HealthCheck {
  HealthCheck({
    Duration stalePollThreshold = _defaultStalePollThreshold,
    this.version = 'dev',
    this.commit = 'local',
    this.buildTime = 'unknown',
  }) : _stalePollThreshold = stalePollThreshold;

  /// Semver + short SHA, e.g. `0.1.0+abc1234`.
  final String version;

  /// Git commit SHA baked in at build time.
  final String commit;

  /// ISO 8601 UTC timestamp of the Docker build.
  final String buildTime;

  final Duration _stalePollThreshold;
  final DateTime _startTime = DateTime.now();
  HttpServer? _server;

  DateTime? _lastPoll;
  DateTime? _lastClaudeSuccess;
  DateTime? _processingStart;
  int _errorCount = 0;

  /// Memory retriever — set after initialization when Voyage AI is enabled.
  MemoryRetriever? memoryRetriever;

  /// Embedding pipeline — set after initialization when Voyage AI is enabled.
  EmbeddingPipeline? embeddingPipeline;

  /// Callback to fetch recent memories by recency (no embedding needed).
  /// Set after database initialization.
  List<MemoryRecord> Function(String chatId, {int limit})?
      getRecentMemories;

  /// Shared API key for authenticating memory API requests.
  /// If null, memory API endpoints return 403.
  String? apiKey;

  /// Callback to fetch recent conversation messages across all chats.
  /// Set after database initialization.
  ///
  /// Parameters:
  /// - [limit]: maximum number of messages to return (across all chats)
  /// - [excludeChatId]: optional chat ID to exclude (e.g. voice chat)
  ///
  /// Returns messages ordered by created_at DESC.
  List<Map<String, Object?>> Function({int limit, String? excludeChatId})?
      getRecentConversations;

  /// Callback for handling game events from the AITW bridge.
  /// Set after the game event router is constructed.
  Future<void> Function(HttpRequest)? onGameEvent;

  /// How long before in-flight message processing is considered stuck.
  /// Fires before the agent timeout (3m) to give early warning.
  static const _stuckProcessingThreshold = Duration(minutes: 2);

  /// Starts the health check HTTP server.
  ///
  /// Returns the actual port (useful when [port] is `0` for tests).
  Future<int> start({int port = 8081}) async {
    _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _server!.listen(_handleRequest);
    return _server!.port;
  }

  /// Stops the health check server.
  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  /// Records a successful poll cycle.
  void recordPoll() {
    _lastPoll = DateTime.now();
  }

  /// Records a successful Claude API response.
  void recordClaudeSuccess() {
    _lastClaudeSuccess = DateTime.now();
  }

  /// Records that message processing has started.
  void recordProcessingStart() {
    _processingStart = DateTime.now();
  }

  /// Records that message processing has finished (or failed).
  void recordProcessingEnd() {
    _processingStart = null;
  }

  /// Increments the cumulative error counter.
  void recordError() {
    _errorCount++;
  }

  void _handleRequest(HttpRequest request) {
    // Handle CORS preflight for all /api/ paths.
    if (request.method == 'OPTIONS' &&
        request.uri.path.startsWith('/api/')) {
      _setCorsHeaders(request);
      request.response
        ..statusCode = HttpStatus.noContent
        ..close();
      return;
    }

    switch (request.uri.path) {
      case '/health':
        _handleHealth(request);
      case '/api/memory/recent':
        _setCorsHeaders(request);
        if (!_checkApiKey(request)) return;
        _handleMemoryRecent(request);
      case '/api/memory/search':
        _setCorsHeaders(request);
        if (!_checkApiKey(request)) return;
        unawaited(_handleMemorySearch(request));
      case '/api/memory/save':
        _setCorsHeaders(request);
        if (!_checkApiKey(request)) return;
        unawaited(_handleMemorySave(request));
      case '/api/conversations/recent':
        _setCorsHeaders(request);
        if (!_checkApiKey(request)) return;
        _handleConversationsRecent(request);
      case '/api/game/event':
        _setCorsHeaders(request);
        if (!_checkApiKey(request)) return;
        if (onGameEvent != null) {
          unawaited(onGameEvent!(request));
        } else {
          _jsonResponse(request, HttpStatus.serviceUnavailable, {
            'error': 'Game event handler not configured',
          });
        }
      default:
        request.response
          ..statusCode = HttpStatus.notFound
          ..close();
    }
  }

  /// Validates the API key from the Authorization header.
  /// Returns true if authorized, false if rejected (response already sent).
  bool _checkApiKey(HttpRequest request) {
    if (apiKey == null) {
      _jsonResponse(request, HttpStatus.forbidden, {
        'error': 'API key not configured',
      });
      return false;
    }

    final auth = request.headers.value('authorization');
    if (auth != 'Bearer $apiKey') {
      _jsonResponse(request, HttpStatus.unauthorized, {
        'error': 'Invalid or missing API key',
      });
      return false;
    }

    return true;
  }

  /// Sets CORS headers on API responses.
  ///
  /// Required because the game client runs on Firebase Hosting (different
  /// origin than the VPS). Uses `*` for now — tighten to the Firebase
  /// domain in production if Caddy isn't handling CORS.
  void _setCorsHeaders(HttpRequest request) {
    request.response.headers
      ..set('Access-Control-Allow-Origin', '*')
      ..set('Access-Control-Allow-Methods', 'POST, GET, OPTIONS')
      ..set('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  }

  void _handleHealth(HttpRequest request) {
    final now = DateTime.now();
    final uptime = now.difference(_startTime);
    final pollStale = _lastPoll != null &&
        now.difference(_lastPoll!) >= _stalePollThreshold;
    final processingStuck = _processingStart != null &&
        now.difference(_processingStart!) >= _stuckProcessingThreshold;
    final isDegraded = pollStale || processingStuck;
    final status = isDegraded ? 'degraded' : 'ok';

    request.response
      ..statusCode = isDegraded
          ? HttpStatus.serviceUnavailable
          : HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(<String, Object?>{
        'status': status,
        'version': version,
        'commit': commit,
        'build_time': buildTime,
        'uptime_seconds': uptime.inSeconds,
        'last_poll': _lastPoll?.toUtc().toIso8601String(),
        'last_claude_success':
            _lastClaudeSuccess?.toUtc().toIso8601String(),
        'processing_since':
            _processingStart?.toUtc().toIso8601String(),
        'error_count': _errorCount,
      }))
      ..close();
  }

  /// GET /api/memory/recent?chat_id=voice&limit=5
  ///
  /// Returns recent memories by date — no embedding or Voyage API call needed.
  /// Designed for fast session context injection.
  void _handleMemoryRecent(HttpRequest request) {
    if (getRecentMemories == null) {
      _jsonResponse(request, HttpStatus.serviceUnavailable, {
        'error': 'Memory system not available',
      });
      return;
    }

    final chatId = request.uri.queryParameters['chat_id'] ?? 'voice';
    final limit =
        int.tryParse(request.uri.queryParameters['limit'] ?? '') ?? 5;

    final records = getRecentMemories!(chatId, limit: limit);

    _jsonResponse(request, HttpStatus.ok, {
      'results': records
          .map((r) => <String, Object?>{
                'text': r.sourceText,
                'date': r.createdAt,
                'visibility': r.visibility.name,
              })
          .toList(),
    });
  }

  /// POST /api/memory/search
  ///
  /// Body: `{ "query": "...", "chat_id": "...", "limit": 5 }`
  /// Returns: `{ "results": [{ "text": "...", "score": 0.85, "date": "..." }] }`
  Future<void> _handleMemorySearch(HttpRequest request) async {
    if (request.method != 'POST') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      await request.response.close();
      return;
    }

    if (memoryRetriever == null) {
      _jsonResponse(request, HttpStatus.serviceUnavailable, {
        'error': 'Memory system not available',
      });
      return;
    }

    try {
      final body = await utf8.decoder.bind(request).join();
      final json = jsonDecode(body) as Map<String, Object?>;
      final query = json['query'] as String?;
      final chatId = json['chat_id'] as String? ?? 'voice';
      final limit = (json['limit'] as num?)?.toInt() ?? 5;

      if (query == null || query.isEmpty) {
        _jsonResponse(request, HttpStatus.badRequest, {
          'error': 'Missing required field: query',
        });
        return;
      }

      final results = await memoryRetriever!.retrieve(
        query,
        chatId,
        topK: limit,
      );

      _jsonResponse(request, HttpStatus.ok, {
        'results': results
            .map((r) => <String, Object?>{
                  'text': r.record.sourceText,
                  'score': r.score,
                  'date': r.record.createdAt,
                  'visibility': r.record.visibility.name,
                })
            .toList(),
      });
    } on FormatException {
      _jsonResponse(request, HttpStatus.badRequest, {
        'error': 'Invalid JSON body',
      });
    }
  }

  /// POST /api/memory/save
  ///
  /// Body: `{ "content": "...", "chat_id": "...", "visibility": "cross_chat" }`
  /// Returns: `{ "ok": true }`
  Future<void> _handleMemorySave(HttpRequest request) async {
    if (request.method != 'POST') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      await request.response.close();
      return;
    }

    if (embeddingPipeline == null) {
      _jsonResponse(request, HttpStatus.serviceUnavailable, {
        'error': 'Memory system not available',
      });
      return;
    }

    try {
      final body = await utf8.decoder.bind(request).join();
      final json = jsonDecode(body) as Map<String, Object?>;
      final content = json['content'] as String?;
      final chatId = json['chat_id'] as String? ?? 'voice';
      final visibilityStr =
          json['visibility'] as String? ?? 'cross_chat';

      if (content == null || content.isEmpty) {
        _jsonResponse(request, HttpStatus.badRequest, {
          'error': 'Missing required field: content',
        });
        return;
      }

      final visibility = MemoryVisibility.values.firstWhere(
        (v) => v.name == visibilityStr,
        orElse: () => MemoryVisibility.crossChat,
      );

      embeddingPipeline!.queue(
        chatId: chatId,
        userText: content,
        assistantText: '[Saved via voice session]',
        senderName: 'Voice User',
        visibility: visibility,
      );

      _jsonResponse(request, HttpStatus.ok, {'ok': true});
    } on FormatException {
      _jsonResponse(request, HttpStatus.badRequest, {
        'error': 'Invalid JSON body',
      });
    }
  }

  /// GET /api/conversations/recent?limit=20&exclude_chat_id=voice
  ///
  /// Returns recent conversation messages grouped by chat_id, so the voice
  /// avatar can see what was discussed on Matrix. Message content is truncated
  /// to 500 characters to keep the response size reasonable.
  void _handleConversationsRecent(HttpRequest request) {
    if (getRecentConversations == null) {
      _jsonResponse(request, HttpStatus.serviceUnavailable, {
        'error': 'Conversation history not available',
      });
      return;
    }

    final limit =
        int.tryParse(request.uri.queryParameters['limit'] ?? '') ?? 20;
    final excludeChatId = request.uri.queryParameters['exclude_chat_id'];

    final rows = getRecentConversations!(
      limit: limit,
      excludeChatId: excludeChatId,
    );

    // Group messages by chat_id, preserving per-chat chronological order.
    final grouped = <String, List<Map<String, Object?>>>{};
    for (final row in rows) {
      final chatId = row['chat_id'] as String;
      grouped.putIfAbsent(chatId, () => []).add(<String, Object?>{
        'role': row['role'],
        'sender_name': row['sender_name'],
        'content': _truncate(row['content'] as String? ?? '', 500),
        'created_at': row['created_at'],
      });
    }

    _jsonResponse(request, HttpStatus.ok, {
      'conversations': [
        for (final entry in grouped.entries)
          <String, Object?>{
            'chat_id': entry.key,
            'messages': entry.value,
          },
      ],
    });
  }

  /// Truncates [text] to [maxLength] characters, appending an ellipsis if cut.
  static String _truncate(String text, int maxLength) {
    if (text.length <= maxLength) return text;
    return '${text.substring(0, maxLength)}...';
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
