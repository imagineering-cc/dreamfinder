/// HTTP client for the Matrix Client-Server API.
///
/// Lightweight wrapper matching the existing [SignalClient] pattern — uses
/// `package:http` directly instead of a heavy Matrix SDK.
///
/// Key endpoints:
/// - `whoAmI()` — verify the bot's identity
/// - `sync()` — long-poll for new events (timeline, invites, member counts)
/// - `sendMessage()` — send plain text + HTML to a room
/// - `joinRoom()` — accept room invites
/// - `sendTypingIndicator()` — show typing state
library;

import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'models.dart';

/// Matrix Client-Server API wrapper.
///
/// Accepts an injectable [http.Client] for testability.
class MatrixClient {
  MatrixClient({
    required this.homeserver,
    required this.accessToken,
    http.Client? client,
  }) : _client = client ?? http.Client();

  /// The Matrix homeserver base URL (e.g., `https://matrix.example.com`).
  final String homeserver;

  /// The bot's access token for authentication.
  final String accessToken;

  final http.Client _client;

  /// Cached bot user ID from [whoAmI].
  String? _botUserId;

  /// Cached room member counts from sync responses (for DM detection).
  final Map<String, int> _roomMemberCounts = {};

  /// Returns the bot's Matrix user ID (e.g., `@bot:server`).
  ///
  /// Caches the result after the first call.
  Future<String> whoAmI() async {
    if (_botUserId != null) return _botUserId!;

    final response = await _get('/_matrix/client/v3/account/whoami');
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    _botUserId = json['user_id'] as String;
    return _botUserId!;
  }

  /// Long-polls the `/sync` endpoint for new events.
  ///
  /// [since] is the `next_batch` token from the previous sync. Pass `null`
  /// for the initial sync.
  ///
  /// [timeout] is the server-side long-poll timeout in milliseconds.
  ///
  /// On initial sync (no [since] token), timeline events are skipped to avoid
  /// replaying old messages. Room state and invites are still processed.
  Future<MatrixSyncResponse> sync({
    String? since,
    int timeout = 30000,
  }) async {
    final isInitialSync = since == null;

    final queryParams = <String, String>{
      'timeout': timeout.toString(),
      if (since != null) 'since': since,
      // On initial sync, filter out timeline events to avoid replaying history.
      // We still want room state (member counts) and invite events.
      if (isInitialSync)
        'filter': jsonEncode(<String, dynamic>{
          'room': <String, dynamic>{
            'timeline': <String, dynamic>{'limit': 0},
          },
        }),
    };

    final uri = Uri.parse('$homeserver/_matrix/client/v3/sync')
        .replace(queryParameters: queryParams);
    // Client-side timeout = server long-poll timeout + 30s buffer.
    final clientTimeout = Duration(milliseconds: timeout + 30000);
    final response = await _getUri(uri, timeout: clientTimeout);
    final json = jsonDecode(response.body) as Map<String, dynamic>;

    return _parseSyncResponse(json);
  }

  /// Sends a text message to [roomId].
  ///
  /// Sends both plain `body` and HTML `formatted_body` for rich rendering.
  /// Uses a unique transaction ID to ensure idempotency.
  Future<String> sendMessage({
    required String roomId,
    required String message,
  }) async {
    final txnId = _generateTxnId();
    final encodedRoomId = Uri.encodeComponent(roomId);

    final body = <String, dynamic>{
      'msgtype': 'm.text',
      'body': message,
      'format': 'org.matrix.custom.html',
      'formatted_body': _textToHtml(message),
    };

    final response = await _put(
      '/_matrix/client/v3/rooms/$encodedRoomId/send/m.room.message/$txnId',
      body: body,
    );

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return json['event_id'] as String? ?? '';
  }

  /// Sends a typing indicator to [roomId].
  ///
  /// The indicator auto-expires after 10 seconds on the server.
  Future<void> sendTypingIndicator({required String roomId}) async {
    final userId = await whoAmI();
    final encodedRoomId = Uri.encodeComponent(roomId);
    final encodedUserId = Uri.encodeComponent(userId);

    await _put(
      '/_matrix/client/v3/rooms/$encodedRoomId/typing/$encodedUserId',
      body: <String, dynamic>{
        'typing': true,
        'timeout': 10000,
      },
    );
  }

  /// Creates a direct message room with [userId] and returns the room ID.
  ///
  /// If a DM room already exists with this user, Matrix may return the
  /// existing room. The room is marked as `is_direct` so clients display
  /// it as a DM.
  Future<String> createDm(String userId) async {
    final response = await _post(
      '/_matrix/client/v3/createRoom',
      body: <String, dynamic>{
        'is_direct': true,
        'invite': <String>[userId],
        'preset': 'trusted_private_chat',
      },
    );

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return json['room_id'] as String;
  }

  /// Joins a room by ID or alias.
  Future<void> joinRoom(String roomIdOrAlias) async {
    final encoded = Uri.encodeComponent(roomIdOrAlias);
    await _post('/_matrix/client/v3/join/$encoded');
  }

  /// Returns `true` if [roomId] is a DM (exactly 2 joined members).
  ///
  /// Uses cached member counts from sync responses.
  bool isDm(String roomId) {
    final count = _roomMemberCounts[roomId];
    return count != null && count == 2;
  }

  /// Checks if [text] contains a mention of the bot.
  ///
  /// Looks for:
  /// 1. Matrix "pill" mention: `<a href="https://matrix.to/#/@bot:server">...</a>`
  /// 2. Display name regex (case-insensitive word boundary match).
  bool isMentioned({
    required String text,
    String? formattedBody,
    required String botDisplayName,
  }) {
    // Check Matrix pill mention in formatted body.
    if (formattedBody != null && _botUserId != null) {
      if (formattedBody.contains('matrix.to/#/$_botUserId')) {
        return true;
      }
    }

    // Fall back to name regex.
    final pattern = RegExp(
      '\\b${RegExp.escape(botDisplayName)}\\b',
      caseSensitive: false,
    );
    return pattern.hasMatch(text);
  }

  // ---------------------------------------------------------------------------
  // Sync response parsing
  // ---------------------------------------------------------------------------

  MatrixSyncResponse _parseSyncResponse(Map<String, dynamic> json) {
    final nextBatch = json['next_batch'] as String? ?? '';
    final events = <MatrixEvent>[];
    final invites = <MatrixInvite>[];
    final memberCounts = <String, int>{};

    final rooms = json['rooms'] as Map<String, dynamic>?;
    if (rooms == null) {
      return MatrixSyncResponse(nextBatch: nextBatch);
    }

    // Joined rooms — timeline events and member counts.
    final join = rooms['join'] as Map<String, dynamic>?;
    if (join != null) {
      for (final entry in join.entries) {
        final roomId = entry.key;
        final roomData = entry.value as Map<String, dynamic>;

        // Parse timeline events.
        final timeline = roomData['timeline'] as Map<String, dynamic>?;
        if (timeline != null) {
          final timelineEvents = timeline['events'] as List<dynamic>?;
          if (timelineEvents != null) {
            for (final eventJson in timelineEvents) {
              events.add(MatrixEvent.fromJson(
                eventJson as Map<String, dynamic>,
                roomId: roomId,
              ));
            }
          }
        }

        // Parse member count from room summary.
        final summary = roomData['summary'] as Map<String, dynamic>?;
        if (summary != null) {
          final joinedCount = summary['m.joined_member_count'] as int?;
          if (joinedCount != null) {
            memberCounts[roomId] = joinedCount;
            _roomMemberCounts[roomId] = joinedCount;
          }
        }
      }
    }

    // Invited rooms.
    final invite = rooms['invite'] as Map<String, dynamic>?;
    if (invite != null) {
      for (final entry in invite.entries) {
        final roomId = entry.key;
        final roomData = entry.value as Map<String, dynamic>;

        // Find the inviter from invite_state events.
        var inviter = '';
        final inviteState = roomData['invite_state'] as Map<String, dynamic>?;
        if (inviteState != null) {
          final stateEvents = inviteState['events'] as List<dynamic>?;
          if (stateEvents != null) {
            for (final event in stateEvents) {
              final eventMap = event as Map<String, dynamic>;
              if (eventMap['type'] == 'm.room.member') {
                inviter = eventMap['sender'] as String? ?? '';
                break;
              }
            }
          }
        }

        invites.add(MatrixInvite(roomId: roomId, inviter: inviter));
      }
    }

    return MatrixSyncResponse(
      nextBatch: nextBatch,
      events: events,
      invites: invites,
      roomMemberCounts: memberCounts,
    );
  }

  // ---------------------------------------------------------------------------
  // HTTP helpers
  // ---------------------------------------------------------------------------

  /// Default client-side timeout for Matrix API calls.
  static const _defaultTimeout = Duration(seconds: 30);

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      };

  Future<http.Response> _get(
    String path, {
    Duration timeout = _defaultTimeout,
  }) async {
    final response = await _client
        .get(Uri.parse('$homeserver$path'), headers: _headers)
        .timeout(timeout);
    _ensureSuccess(response);
    return response;
  }

  Future<http.Response> _getUri(
    Uri uri, {
    Duration timeout = _defaultTimeout,
  }) async {
    final response =
        await _client.get(uri, headers: _headers).timeout(timeout);
    _ensureSuccess(response);
    return response;
  }

  Future<http.Response> _post(
    String path, {
    Map<String, dynamic>? body,
    Duration timeout = _defaultTimeout,
  }) async {
    final response = await _client
        .post(
          Uri.parse('$homeserver$path'),
          headers: _headers,
          body: body != null ? jsonEncode(body) : null,
        )
        .timeout(timeout);
    _ensureSuccess(response);
    return response;
  }

  Future<http.Response> _put(
    String path, {
    required Map<String, dynamic> body,
    Duration timeout = _defaultTimeout,
  }) async {
    final response = await _client
        .put(
          Uri.parse('$homeserver$path'),
          headers: _headers,
          body: jsonEncode(body),
        )
        .timeout(timeout);
    _ensureSuccess(response);
    return response;
  }

  void _ensureSuccess(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw MatrixApiException(
        statusCode: response.statusCode,
        body: response.body,
      );
    }
  }

  /// Generates a unique transaction ID for idempotent message sends.
  static String _generateTxnId() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final random =
        Random.secure().nextInt(0xFFFFFF).toRadixString(16).padLeft(6, '0');
    return 'txn_${timestamp}_$random';
  }

  /// Converts plain text to HTML for `formatted_body`.
  ///
  /// Supports basic Markdown: **bold**, *italic*, `inline code`,
  /// ```code blocks```, and line breaks. Escapes HTML entities first.
  static String _textToHtml(String text) {
    var html = text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');

    // Code blocks (``` ... ```) — must come before inline code.
    html = html.replaceAllMapped(
      RegExp(r'```(\w*)\n?([\s\S]*?)```'),
      (m) => '<pre><code>${m.group(2)}</code></pre>',
    );

    // Inline code (` ... `).
    html = html.replaceAllMapped(
      RegExp(r'`([^`]+)`'),
      (m) => '<code>${m.group(1)}</code>',
    );

    // Bold (**text**).
    html = html.replaceAllMapped(
      RegExp(r'\*\*(.+?)\*\*'),
      (m) => '<strong>${m.group(1)}</strong>',
    );

    // Italic (*text*) — after bold to avoid conflicts.
    html = html.replaceAllMapped(
      RegExp(r'\*(.+?)\*'),
      (m) => '<em>${m.group(1)}</em>',
    );

    // Line breaks.
    html = html.replaceAll('\n', '<br/>');

    return html;
  }
}

/// Exception thrown when a Matrix API call returns an error status.
class MatrixApiException implements Exception {
  const MatrixApiException({required this.statusCode, required this.body});

  final int statusCode;
  final String body;

  @override
  String toString() => 'MatrixApiException($statusCode): $body';
}
