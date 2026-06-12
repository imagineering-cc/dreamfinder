/// Custom tools for proactive direct messaging.
///
/// `dm_user`: open a direct message with a Matrix user and send them a message
/// — e.g. to onboard someone by DMing them an invite link.
///
/// `start_private_chat`: open a 1:1 chat with a user on a *bridged platform*
/// (WhatsApp / Telegram / Signal / Discord) via the corresponding mautrix
/// bridge and send them a message — the bot's only way to reach someone who
/// has no Matrix account. Drives the bridge's `start-chat` command in that
/// platform's management room (the grammar is uniform across the mautrix
/// bridges), polls for the bridge's reply (out-of-band — see
/// [MatrixClient.getRecentMessages]), joins the created portal room, and
/// sends the opener into it. The recipient just gets a normal message on
/// their platform; their reply flows back into the portal where the normal
/// DM response path handles it (portal rooms count as DMs once bridge bots
/// are excluded from member counting — see [MatrixClient.bridgeBotIds]).
///
/// Which platforms appear in the tool's `platform` enum is **explicit system
/// state**: a platform is available iff its management room is configured.
/// No platform is inferred, defaulted-in, or guessed at runtime.
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
/// `start_private_chat` is only registered when at least one platform
/// management room (the Matrix room shared with that bridge's bot where
/// `start-chat` commands are issued) AND [bridgeBotIds] are configured — the
/// bridge bot identity is what authenticates the bridge's reply, so the tool
/// refuses to exist without it. Each platform appears in the tool's
/// `platform` enum iff its room is configured. [replyPollInterval] and
/// [replyTimeout] exist for tests — production uses the defaults.
void registerMessagingTools(
  ToolRegistry registry,
  MatrixClient matrixClient, {
  String? whatsappManagementRoom,
  String? telegramManagementRoom,
  String? signalManagementRoom,
  String? discordManagementRoom,
  Set<String> bridgeBotIds = const {},
  Duration replyPollInterval = const Duration(seconds: 2),
  Duration replyTimeout = const Duration(seconds: 30),
}) {
  registry.registerCustomTool(_dmUserTool(matrixClient));

  // A platform exists iff its management room is configured — registration
  // is the single gate; the handler never needs a "platform not configured"
  // path for enum values the model can see.
  //
  // Each platform also carries ITS OWN trusted bridge-bot set, derived from
  // the flat BRIDGE_BOT_IDS list by mautrix naming convention (the localpart
  // starts with the platform key: @whatsappbot, @telegrambot, ...). This
  // encodes the invariant that a reply in the Telegram management room is
  // only authoritative from the TELEGRAM bridge bot — a cross-bridge reply
  // must not be able to name the portal. When no ID matches the convention
  // (custom bot names), fall back to the full set: room membership is then
  // the only boundary, which matches the pre-refactor behavior.
  Set<String> botsFor(String key) {
    final matching = bridgeBotIds
        .where((id) => id.startsWith('@') && id.substring(1).startsWith(key))
        .toSet();
    return matching.isNotEmpty ? matching : bridgeBotIds;
  }

  final platforms = <String, _Platform>{
    if (whatsappManagementRoom != null && whatsappManagementRoom.isNotEmpty)
      'whatsapp': _Platform(
        key: 'whatsapp',
        label: 'WhatsApp',
        managementRoom: whatsappManagementRoom,
        idKind: _IdKind.phone,
        bridgeBotIds: botsFor('whatsapp'),
      ),
    if (telegramManagementRoom != null && telegramManagementRoom.isNotEmpty)
      'telegram': _Platform(
        key: 'telegram',
        label: 'Telegram',
        managementRoom: telegramManagementRoom,
        idKind: _IdKind.phone,
        bridgeBotIds: botsFor('telegram'),
      ),
    if (signalManagementRoom != null && signalManagementRoom.isNotEmpty)
      'signal': _Platform(
        key: 'signal',
        label: 'Signal',
        managementRoom: signalManagementRoom,
        idKind: _IdKind.phone,
        bridgeBotIds: botsFor('signal'),
      ),
    if (discordManagementRoom != null && discordManagementRoom.isNotEmpty)
      'discord': _Platform(
        key: 'discord',
        label: 'Discord',
        managementRoom: discordManagementRoom,
        idKind: _IdKind.discordUser,
        bridgeBotIds: botsFor('discord'),
      ),
  };

  if (platforms.isNotEmpty && bridgeBotIds.isNotEmpty) {
    registry.registerCustomTool(_startPrivateChatTool(
      matrixClient,
      platforms: platforms,
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
        'homeserver — for WhatsApp/Telegram/Signal/Discord contacts use '
        'start_private_chat instead. '
        'The recipient receives a DM invite they must accept before the message '
        'is visible. Each call opens a fresh DM room, so send a complete '
        'message rather than many fragments. Admin-only.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'user_id': <String, dynamic>{
          'type': 'string',
          'description': 'Full Matrix user ID of the recipient, e.g. '
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
  // `args` crosses the type-system boundary (model-generated JSON) — validate
  // with `is` checks rather than casts so a malformed call returns a
  // structured error instead of throwing a TypeError.
  final userId = args['user_id'];
  final message = args['message'];

  // A valid Matrix user ID is `@localpart:server`. Validate before creating a
  // room so a typo doesn't spawn an empty DM.
  if (userId is! String || !userId.startsWith('@') || !userId.contains(':')) {
    return jsonEncode(<String, dynamic>{
      'error': 'user_id must be a full Matrix ID like @alice:imagineering.cc',
    });
  }
  if (message is! String || message.trim().isEmpty) {
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
// start_private_chat — bridged-platform 1:1 via the mautrix bridges
// -----------------------------------------------------------------------------

/// What shape of identifier a platform's bridge resolves.
enum _IdKind { phone, discordUser }

/// One bridged platform the tool can open chats on. Existence of an instance
/// == the platform is configured; there is deliberately no "configured but
/// disabled" state.
class _Platform {
  const _Platform({
    required this.key,
    required this.label,
    required this.managementRoom,
    required this.idKind,
    required this.bridgeBotIds,
  });

  /// Stable lowercase key used in the tool's `platform` enum, e.g. `whatsapp`.
  final String key;

  /// Human label used in messages back to the model, e.g. `WhatsApp`.
  final String label;

  /// The Matrix room shared with this platform's bridge bot where
  /// `start-chat` commands are issued.
  final String managementRoom;

  final _IdKind idKind;

  /// The bridge bot MXIDs whose replies are authoritative for THIS
  /// platform's management room. Derived per-platform so a different
  /// bridge's bot cannot name the portal even if room membership drifts.
  final Set<String> bridgeBotIds;
}

/// Matches an E.164-style international phone number after normalization:
/// mandatory `+`, then 6-15 digits not starting with 0. The mautrix bridges
/// resolve identifiers internationally, so an ambiguous local-format number
/// (no `+`) is rejected rather than guessed at.
final _phonePattern = RegExp(r'^\+[1-9][0-9]{5,14}$');

/// Matches a Discord recipient after normalization (leading `@` stripped):
/// either a numeric snowflake ID (15-21 digits) or a modern Discord username
/// (2-32 chars of lowercase alphanumerics, underscore, period — Discord also
/// rejects leading/trailing/consecutive periods, mirrored here so junk fails
/// fast). The bridge still gives the informative error for a well-formed
/// username it cannot resolve.
final _discordUserPattern =
    RegExp(r'^([0-9]{15,21}|(?!\.)(?!.*\.\.)[a-z0-9._]{2,32}(?<!\.))$');

/// Extracts a Matrix room ID from a matrix.to permalink in the bridge's
/// reply, e.g. `https://matrix.to/#/!abc123%3Aexample.com?via=example.com`.
/// The room ID may be URL-encoded (`!` → `%21`, `:` → `%3A`) and may carry
/// `?via=` parameters — both are handled by the capture + decode.
final _matrixToRoomPattern = RegExp(r'matrix\.to/#/((?:!|%21)[^?\s"<>)\]]+)');

CustomToolDef _startPrivateChatTool(
  MatrixClient matrixClient, {
  required Map<String, _Platform> platforms,
  required Duration pollInterval,
  required Duration timeout,
}) {
  final labels = platforms.values.map((p) => p.label).join(', ');
  return CustomToolDef(
    name: 'start_private_chat',
    description:
        'Proactively open a private 1:1 chat with someone on a bridged '
        'platform ($labels) and send them a message — e.g. to welcome a new '
        'community member and ask for their email so they can be invited to '
        'Outline. The recipient just receives a normal message from the '
        'bot\'s own account on that platform; their reply arrives back here '
        'as a direct message. WhatsApp/Telegram/Signal take a full '
        'international phone number starting with +; Discord takes a '
        'username or numeric user ID. Each call is a cold outbound message — '
        'send one complete, warm message rather than fragments. NOTE: the '
        'bot is unresponsive to other rooms for up to ~30s while the bridge '
        'sets up the chat. Admin-only.',
    inputSchema: <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'platform': <String, dynamic>{
          'type': 'string',
          // Only configured platforms exist — the model cannot pick one the
          // system can't deliver on (explicit identity over inference).
          'enum': platforms.keys.toList(),
          'description': 'Which bridged platform to open the chat on.',
        },
        'identifier': <String, dynamic>{
          'type': 'string',
          'description':
              'Who to message. Phone number in international format with '
                  'leading + (e.g. +61400000000; spaces and dashes tolerated) '
                  'for WhatsApp/Telegram/Signal; username or numeric user ID '
                  'for Discord.',
        },
        'message': <String, dynamic>{
          'type': 'string',
          'description': 'The message text to send.',
        },
      },
      'required': <String>['platform', 'identifier', 'message'],
    },
    // Cold outbound DMs are a spam/abuse vector — only admins may trigger them.
    requiresAdmin: true,
    handler: (args) => _startPrivateChat(
      matrixClient,
      args,
      platforms: platforms,
      pollInterval: pollInterval,
      timeout: timeout,
    ),
  );
}

Future<String> _startPrivateChat(
  MatrixClient matrixClient,
  Map<String, dynamic> args, {
  required Map<String, _Platform> platforms,
  required Duration pollInterval,
  required Duration timeout,
}) async {
  // `args` crosses the type-system boundary (model-generated JSON) — validate
  // with `is` checks rather than casts so a malformed call returns a
  // structured error instead of throwing a TypeError.
  //
  // NO legacy `phone` alias here: `identifier` is in the schema's `required`
  // list, so a schema-honoring caller always sends it — an alias only
  // reachable by bypassing validation is a contract lie, not compatibility
  // (cage-match, Carnot). The model reads the fresh schema every session.
  final rawPlatform = args['platform'];
  final rawIdentifier = args['identifier'];
  final message = args['message'];

  final platform = rawPlatform is String ? platforms[rawPlatform] : null;
  if (platform == null) {
    return jsonEncode(<String, dynamic>{
      'error': 'platform must be one of: ${platforms.keys.join(', ')} '
          '(got "${rawPlatform is String ? rawPlatform : rawPlatform.runtimeType}"). '
          'Platforms are only listed when their bridge is configured.',
    });
  }

  final String identifier;
  switch (platform.idKind) {
    case _IdKind.phone:
      // Normalize: tolerate spaces/dashes/parens that humans paste in.
      final phone = rawIdentifier is String
          ? rawIdentifier.replaceAll(RegExp(r'[\s\-()]'), '')
          : '';
      if (!_phonePattern.hasMatch(phone)) {
        return jsonEncode(<String, dynamic>{
          'error': '${platform.label} needs an international number with leading '
              '+ like +61400000000 '
              '(got "${rawIdentifier is String ? rawIdentifier : rawIdentifier.runtimeType}")',
        });
      }
      identifier = phone;
    case _IdKind.discordUser:
      // Normalize: strip a pasted leading @ and surrounding whitespace.
      final user = rawIdentifier is String
          ? rawIdentifier.trim().replaceFirst(RegExp(r'^@'), '')
          : '';
      if (!_discordUserPattern.hasMatch(user)) {
        return jsonEncode(<String, dynamic>{
          'error': '${platform.label} needs a username (lowercase letters, '
              'digits, underscore, period) or numeric user ID '
              '(got "${rawIdentifier is String ? rawIdentifier : rawIdentifier.runtimeType}")',
        });
      }
      identifier = user;
  }

  if (message is! String || message.trim().isEmpty) {
    return jsonEncode(<String, dynamic>{
      'error': 'message is required and cannot be empty',
    });
  }

  try {
    // 1. Issue the bridge command. The `start-chat` grammar is uniform across
    //    the mautrix bridges; the bridge replies in the same room with a
    //    matrix.to permalink to the portal room (creating it if needed).
    final commandEventId = await matrixClient.sendMessage(
      roomId: platform.managementRoom,
      message: 'start-chat $identifier',
    );

    // 2. Poll for the bridge's reply. We poll /messages instead of waiting on
    //    /sync because this handler runs *inside* the sequential sync loop —
    //    awaiting a future sync event from here would deadlock the bot.
    final reply = await _awaitPortalReply(
      matrixClient,
      managementRoom: platform.managementRoom,
      // Platform-local trust: only THIS platform's bridge bot may name the
      // portal, even if another bridge's bot is somehow in the room.
      bridgeBotIds: platform.bridgeBotIds,
      commandEventId: commandEventId,
      pollInterval: pollInterval,
      timeout: timeout,
      platformLabel: platform.label,
    );
    final String portal;
    switch (reply) {
      case _PortalFailed(:final reason):
        return jsonEncode(<String, dynamic>{'error': reason});
      case _PortalFound(:final roomId):
        portal = roomId;
    }

    // 3. Join the portal. The bridge invites us, but the loop's auto-join is
    //    blocked while this handler runs — join explicitly. /join on a room
    //    we're already a member of is idempotent (200), so any failure here
    //    is a real one (permissions, bad room, bridge misbehavior) and is
    //    surfaced with join context rather than masked by a less diagnostic
    //    send error.
    try {
      await matrixClient.joinRoom(portal);
    } on Exception catch (e) {
      return jsonEncode(<String, dynamic>{
        'error': 'Bridge created portal $portal but joining it failed: $e',
      });
    }

    // 4. Send the opener into the portal → delivered to the platform.
    await matrixClient.sendMessage(roomId: portal, message: message);

    return jsonEncode(<String, dynamic>{
      'ok': true,
      'platform': platform.key,
      'portal_room_id': portal,
      'note': '${platform.label} message sent to $identifier. Their reply '
          'will arrive as a direct message from this portal room.',
    });
  } on Exception catch (e) {
    return jsonEncode(<String, dynamic>{
      'error': 'Failed to start ${platform.label} chat with $identifier: $e',
    });
  }
}

/// Result of waiting for the bridge's `start-chat` reply.
sealed class _PortalReply {
  const _PortalReply();
}

class _PortalFound extends _PortalReply {
  const _PortalFound(this.roomId);
  final String roomId;
}

class _PortalFailed extends _PortalReply {
  const _PortalFailed(this.reason);
  final String reason;
}

/// Polls [managementRoom] for the bridge bot's reply to our `start-chat`
/// command and extracts the portal room ID from its matrix.to permalink.
///
/// Trust model: only events whose sender is in [bridgeBotIds] are considered
/// — a permalink posted by anyone else in the management room must not be
/// able to redirect the opener. Only events *newer* than [commandEventId]
/// are considered: the newest-first scan hard-stops at the command event.
/// When the command event is not in the fetched page, every event in the
/// page is newer than it (room history is totally ordered), so the whole
/// page is scanned.
///
/// A bridge reply without a permalink (e.g. "user is not on WhatsApp")
/// keeps the poll alive until [timeout] in case the link arrives in a
/// follow-up message; on timeout the last such reply is surfaced as the
/// error detail.
Future<_PortalReply> _awaitPortalReply(
  MatrixClient matrixClient, {
  required String managementRoom,
  required Set<String> bridgeBotIds,
  required String commandEventId,
  required Duration pollInterval,
  required Duration timeout,
  required String platformLabel,
}) async {
  final deadline = DateTime.now().add(timeout);
  String? lastBridgeText;

  while (true) {
    List<MatrixEvent> recent;
    try {
      recent = await matrixClient.getRecentMessages(roomId: managementRoom);
    } on Exception {
      recent = const [];
    }

    // Newest-first: scan until we reach our own command event — everything
    // before it in the list is newer than the command.
    for (final event in recent) {
      if (event.eventId == commandEventId) break;
      // Only the bridge bot's replies are trusted; a permalink from any
      // other member of the management room must not redirect the opener.
      if (!bridgeBotIds.contains(event.sender)) continue;
      final text = event.body;
      if (text == null || text.isEmpty) continue;

      // Permalinks live in the HTML body when present; fall back to plain.
      final haystack = '${event.formattedBody ?? ''}\n$text';
      final match = _matrixToRoomPattern.firstMatch(haystack);
      if (match != null) {
        // decodeComponent throws ArgumentError (an Error, not Exception) on
        // malformed percent-encoding — contain it here so a mangled reply
        // degrades to "keep polling" rather than escaping the handler.
        try {
          return _PortalFound(Uri.decodeComponent(match.group(1)!));
        } on ArgumentError {
          lastBridgeText = text;
          continue;
        }
      }
      lastBridgeText = text;
    }

    if (DateTime.now().isAfter(deadline)) {
      return _PortalFailed(
        lastBridgeText != null
            ? 'Bridge did not return a chat link. Bridge said: $lastBridgeText'
            : 'Timed out waiting for the $platformLabel bridge to respond.',
      );
    }
    await Future<void>.delayed(pollInterval);
  }
}
