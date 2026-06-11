/// Custom tools for proactive direct messaging.
///
/// `dm_user`: open a direct message with a Matrix user and send them a message
/// — e.g. to onboard someone by DMing them an invite link.
///
/// `start_private_chat`: open a 1:1 chat with a *WhatsApp* user via the
/// mautrix-whatsapp bridge and send them a message — the bot's only way to
/// reach someone who has no Matrix account. Drives the bridge's `start-chat`
/// command in the bot's WhatsApp management room, polls for the bridge's
/// reply (out-of-band — see [MatrixClient.getRecentMessages]), joins the
/// created portal room, and sends the opener into it. The recipient just
/// gets a WhatsApp message; their reply flows back into the portal where the
/// normal DM response path handles it (portal rooms count as DMs once
/// bridge bots are excluded from member counting — see
/// [MatrixClient.bridgeBotIds]).
///
/// Both tools are gated admin-only: cold-DMing arbitrary people is an abuse
/// vector, so only an admin may trigger them.
library;

import 'dart:convert';

import '../agent/tool_registry.dart';
import '../matrix/matrix_client.dart';
import '../matrix/models.dart';

/// Registers the proactive-DM tools with the [registry].
///
/// `start_private_chat` is only registered when [whatsappManagementRoom] is
/// configured (the Matrix room shared with the WhatsApp bridge bot where
/// `start-chat` commands are issued). [replyPollInterval] and [replyTimeout]
/// exist for tests — production uses the defaults.
void registerMessagingTools(
  ToolRegistry registry,
  MatrixClient matrixClient, {
  String? whatsappManagementRoom,
  Duration replyPollInterval = const Duration(seconds: 2),
  Duration replyTimeout = const Duration(seconds: 30),
}) {
  registry.registerCustomTool(_dmUserTool(matrixClient));
  if (whatsappManagementRoom != null && whatsappManagementRoom.isNotEmpty) {
    registry.registerCustomTool(_startPrivateChatTool(
      matrixClient,
      managementRoom: whatsappManagementRoom,
      pollInterval: replyPollInterval,
      timeout: replyTimeout,
    ));
  }
}

CustomToolDef _dmUserTool(MatrixClient matrixClient) {
  return CustomToolDef(
    name: 'dm_user',
    description:
        'Proactively open a direct message with a Matrix user and send them a '
        'message — e.g. to onboard someone by DMing them a Kan invite link. '
        'LIMITATIONS: only works for users with a Matrix account on this '
        'homeserver — for WhatsApp contacts use start_private_chat instead. '
        'The recipient receives a DM invite they must accept before the message '
        'is visible. Each call opens a fresh DM room, so send a complete '
        'message rather than many fragments. Admin-only.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'user_id': <String, dynamic>{
          'type': 'string',
          'description':
              'Full Matrix user ID of the recipient, e.g. '
                  '@alice:imagineering.cc',
        },
        'message': <String, dynamic>{
          'type': 'string',
          'description': 'The message text to send.',
        },
      },
      'required': <String>['user_id', 'message'],
    },
    // Cold outbound DMs are a spam/abuse vector — only admins may trigger them.
    requiresAdmin: true,
    handler: (args) => _dmUser(matrixClient, args),
  );
}

Future<String> _dmUser(
  MatrixClient matrixClient,
  Map<String, dynamic> args,
) async {
  final userId = args['user_id'] as String?;
  final message = args['message'] as String?;

  // A valid Matrix user ID is `@localpart:server`. Validate before creating a
  // room so a typo doesn't spawn an empty DM.
  if (userId == null || !userId.startsWith('@') || !userId.contains(':')) {
    return jsonEncode(<String, dynamic>{
      'error': 'user_id must be a full Matrix ID like @alice:imagineering.cc',
    });
  }
  if (message == null || message.trim().isEmpty) {
    return jsonEncode(<String, dynamic>{
      'error': 'message is required and cannot be empty',
    });
  }

  try {
    final roomId = await matrixClient.createDm(userId);
    await matrixClient.sendMessage(roomId: roomId, message: message);
    return jsonEncode(<String, dynamic>{
      'ok': true,
      'room_id': roomId,
      'note': 'DM sent to $userId. They must accept the room invite to see it. '
          'Only Matrix users on this homeserver are reachable this way.',
    });
  } on Exception catch (e) {
    return jsonEncode(<String, dynamic>{
      'error': 'Failed to DM $userId: $e',
    });
  }
}

// -----------------------------------------------------------------------------
// start_private_chat — WhatsApp 1:1 via the mautrix bridge
// -----------------------------------------------------------------------------

/// Matches a phone number in international format after normalization
/// (digits only, optional leading `+`).
final _phonePattern = RegExp(r'^\+?[0-9]{6,15}$');

/// Extracts a Matrix room ID from a matrix.to permalink in the bridge's
/// reply, e.g. `https://matrix.to/#/!abc123%3Aexample.com?via=example.com`.
/// The room ID may be URL-encoded (`!` → `%21`, `:` → `%3A`) and may carry
/// `?via=` parameters — both are handled by the capture + decode.
final _matrixToRoomPattern =
    RegExp(r'matrix\.to/#/((?:!|%21)[^?\s"<>)\]]+)');

CustomToolDef _startPrivateChatTool(
  MatrixClient matrixClient, {
  required String managementRoom,
  required Duration pollInterval,
  required Duration timeout,
}) {
  return CustomToolDef(
    name: 'start_private_chat',
    description:
        'Proactively open a private 1:1 WhatsApp chat with someone via the '
        'WhatsApp bridge and send them a message — e.g. to welcome a new '
        'community member and ask for their email so they can be invited to '
        'Outline. The recipient just receives a normal WhatsApp message from '
        'the bot\'s own WhatsApp number; their reply arrives back here as a '
        'direct message. Use a full international phone number. Each call is '
        'a cold outbound message — send one complete, warm message rather '
        'than fragments. Admin-only.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'phone': <String, dynamic>{
          'type': 'string',
          'description':
              'Phone number in international format, e.g. +61400000000. '
                  'Spaces and dashes are tolerated.',
        },
        'message': <String, dynamic>{
          'type': 'string',
          'description': 'The message text to send on WhatsApp.',
        },
      },
      'required': <String>['phone', 'message'],
    },
    // Cold outbound DMs are a spam/abuse vector — only admins may trigger them.
    requiresAdmin: true,
    handler: (args) => _startPrivateChat(
      matrixClient,
      args,
      managementRoom: managementRoom,
      pollInterval: pollInterval,
      timeout: timeout,
    ),
  );
}

Future<String> _startPrivateChat(
  MatrixClient matrixClient,
  Map<String, dynamic> args, {
  required String managementRoom,
  required Duration pollInterval,
  required Duration timeout,
}) async {
  final rawPhone = args['phone'] as String?;
  final message = args['message'] as String?;

  // Normalize: tolerate spaces/dashes/parens that humans paste in.
  final phone = rawPhone?.replaceAll(RegExp(r'[\s\-()]'), '') ?? '';
  if (!_phonePattern.hasMatch(phone)) {
    return jsonEncode(<String, dynamic>{
      'error': 'phone must be an international number like +61400000000 '
          '(got "${rawPhone ?? ''}")',
    });
  }
  if (message == null || message.trim().isEmpty) {
    return jsonEncode(<String, dynamic>{
      'error': 'message is required and cannot be empty',
    });
  }

  try {
    // 1. Issue the bridge command. The bridge replies in the same room with a
    //    matrix.to permalink to the portal room (creating it if needed).
    final commandEventId = await matrixClient.sendMessage(
      roomId: managementRoom,
      message: 'start-chat $phone',
    );

    // 2. Poll for the bridge's reply. We poll /messages instead of waiting on
    //    /sync because this handler runs *inside* the sequential sync loop —
    //    awaiting a future sync event from here would deadlock the bot.
    final portalRoomId = await _awaitPortalReply(
      matrixClient,
      managementRoom: managementRoom,
      commandEventId: commandEventId,
      pollInterval: pollInterval,
      timeout: timeout,
    );
    if (portalRoomId.error != null) {
      return jsonEncode(<String, dynamic>{'error': portalRoomId.error});
    }
    final portal = portalRoomId.roomId!;

    // 3. Join the portal. The bridge invites us, but the loop's auto-join is
    //    blocked while this handler runs — join explicitly. Tolerate failure:
    //    if we're already joined (e.g. an existing chat), /join still 200s on
    //    most servers, but don't let an edge case kill the send.
    try {
      await matrixClient.joinRoom(portal);
    } on Exception {
      // Already joined, or join raced the invite — try the send regardless.
    }

    // 4. Send the opener into the portal → delivered to WhatsApp.
    await matrixClient.sendMessage(roomId: portal, message: message);

    return jsonEncode(<String, dynamic>{
      'ok': true,
      'portal_room_id': portal,
      'note': 'WhatsApp message sent to $phone. Their reply will arrive as a '
          'direct message from this portal room.',
    });
  } on Exception catch (e) {
    return jsonEncode(<String, dynamic>{
      'error': 'Failed to start WhatsApp chat with $phone: $e',
    });
  }
}

/// Result of waiting for the bridge's `start-chat` reply: either a portal
/// room ID or an error description.
class _PortalReply {
  const _PortalReply.ok(this.roomId) : error = null;
  const _PortalReply.failed(this.error) : roomId = null;

  final String? roomId;
  final String? error;
}

/// Polls [managementRoom] for the bridge bot's reply to our `start-chat`
/// command (the first message newer than [commandEventId] from another
/// sender), and extracts the portal room ID from its matrix.to permalink.
///
/// A reply without a permalink (e.g. "user is not on WhatsApp") keeps the
/// poll alive until [timeout] in case the link arrives in a follow-up
/// message; on timeout the last such reply is surfaced as the error detail.
Future<_PortalReply> _awaitPortalReply(
  MatrixClient matrixClient, {
  required String managementRoom,
  required String commandEventId,
  required Duration pollInterval,
  required Duration timeout,
}) async {
  final botUserId = await matrixClient.whoAmI();
  final deadline = DateTime.now().add(timeout);
  String? lastBridgeText;

  while (true) {
    List<MatrixEvent> recent;
    try {
      recent = await matrixClient.getRecentMessages(roomId: managementRoom);
    } on Exception {
      recent = const [];
    }

    // Newest-first: scan replies until we reach our own command event —
    // everything before it in the list is newer than the command.
    for (final event in recent) {
      if (event.eventId == commandEventId) break;
      if (event.sender == botUserId) continue;
      final text = event.body;
      if (text == null || text.isEmpty) continue;

      // Permalinks live in the HTML body when present; fall back to plain.
      final haystack = '${event.formattedBody ?? ''}\n$text';
      final match = _matrixToRoomPattern.firstMatch(haystack);
      if (match != null) {
        final roomId = Uri.decodeComponent(match.group(1)!);
        return _PortalReply.ok(roomId);
      }
      lastBridgeText = text;
    }

    if (DateTime.now().isAfter(deadline)) {
      return _PortalReply.failed(
        lastBridgeText != null
            ? 'Bridge did not return a chat link. Bridge said: $lastBridgeText'
            : 'Timed out waiting for the WhatsApp bridge to respond.',
      );
    }
    await Future<void>.delayed(pollInterval);
  }
}
