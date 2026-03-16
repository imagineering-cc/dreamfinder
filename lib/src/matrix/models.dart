/// Data models for the Matrix Client-Server API.
///
/// Lightweight DTOs parsed from Matrix sync responses. No SDK dependency —
/// just `dart:convert` and the `http` package.
library;

/// A timeline event from a Matrix room.
class MatrixEvent {
  const MatrixEvent({
    required this.eventId,
    required this.roomId,
    required this.sender,
    required this.type,
    required this.originServerTs,
    required this.content,
  });

  /// Parses a timeline event from the `/sync` response JSON.
  factory MatrixEvent.fromJson(
    Map<String, dynamic> json, {
    required String roomId,
  }) {
    return MatrixEvent(
      eventId: json['event_id'] as String? ?? '',
      roomId: roomId,
      sender: json['sender'] as String? ?? '',
      type: json['type'] as String? ?? '',
      originServerTs: json['origin_server_ts'] as int? ?? 0,
      content: json['content'] as Map<String, dynamic>? ?? const {},
    );
  }

  final String eventId;

  /// The room this event belongs to (`!abc:server`).
  final String roomId;

  /// The sender's Matrix user ID (`@user:server`).
  final String sender;

  /// Event type (e.g., `m.room.message`).
  final String type;

  /// Server timestamp in milliseconds since epoch.
  final int originServerTs;

  /// Event content — structure depends on [type].
  final Map<String, dynamic> content;

  /// Plain text body for `m.room.message` events.
  String? get body => content['body'] as String?;

  /// HTML-formatted body (if available).
  String? get formattedBody => content['formatted_body'] as String?;

  /// The `msgtype` field (e.g., `m.text`, `m.image`).
  String? get msgType => content['msgtype'] as String?;

  /// Whether this event is a text message with a non-empty body.
  bool get hasTextMessage =>
      type == 'm.room.message' && msgType == 'm.text' && body != null;
}

/// Parsed response from the Matrix `/sync` endpoint.
class MatrixSyncResponse {
  const MatrixSyncResponse({
    required this.nextBatch,
    this.events = const [],
    this.invites = const [],
    this.roomMemberCounts = const {},
  });

  /// The `next_batch` token to use for the next sync request.
  final String nextBatch;

  /// Timeline events from joined rooms.
  final List<MatrixEvent> events;

  /// Pending room invites.
  final List<MatrixInvite> invites;

  /// Joined member counts per room (for DM detection).
  final Map<String, int> roomMemberCounts;
}

/// A pending room invite from the `/sync` response.
class MatrixInvite {
  const MatrixInvite({
    required this.roomId,
    required this.inviter,
  });

  final String roomId;

  /// The Matrix user ID of whoever sent the invite.
  final String inviter;
}
