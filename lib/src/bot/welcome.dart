/// Deciding whether — and how — to welcome a member who joined a room.
///
/// Extracted from the main loop so the decision is unit-testable in isolation
/// (the inline version welcomed every membership event, including bridge
/// puppets, producing repeating "Welcome pvt pvt!" spam).
library;

/// Bridge/relay puppet MXID namespace prefixes.
///
/// A member whose MXID begins with one of these is an appservice ghost — an
/// unresolved WhatsApp/Signal/Telegram contact, or the superbridge relay
/// puppet — never a real human River can onboard. Welcoming them is what
/// produced the "Welcome pvt pvt!" spam: the puppet's contact name is
/// unresolved (`pvt pvt`), and the bridge re-emits its join every resync, so
/// the welcome fires again and again.
///
/// These mirror the mautrix appservice registration namespaces. The real
/// prod prefixes MUST be verified against the live member list before deploy
/// (see the PR description) — a namespace typo here silently re-opens the spam.
const puppetMxidPrefixes = <String>[
  '@_relay_',
  '@whatsapp_',
  '@signal_',
  '@signalgo_',
  '@telegram_',
  '@discord_',
  '@slack_',
];

/// Returns `true` if [sender] is a bridge/relay puppet rather than a real user.
///
/// Checks, in order: the explicit bridge bot MXIDs ([bridgeBotIds]), River's
/// own relayed puppets ([selfPuppetIds]), then the appservice namespace
/// [puppetMxidPrefixes].
bool isBridgePuppet(
  String sender, {
  Set<String> bridgeBotIds = const {},
  List<String> selfPuppetIds = const [],
}) {
  if (bridgeBotIds.contains(sender)) return true;
  if (selfPuppetIds.contains(sender)) return true;
  for (final prefix in puppetMxidPrefixes) {
    if (sender.startsWith(prefix)) return true;
  }
  return false;
}

/// The `bot_metadata` dedup key for a welcomed (room, sender) pair.
///
/// Persisting this means a bridge resync that re-emits an old join — or River
/// restarting — never re-welcomes someone already greeted.
String welcomeDedupKey(String roomId, String sender) =>
    'welcomed::$roomId::$sender';

/// Decides whether to welcome a joining member, returning the message to send
/// or `null` to stay silent.
///
/// River welcomes only when ALL hold:
/// - the event is a genuine join ([isMemberJoin] — not a profile update),
/// - the room is a hub room River converses in ([hubRoomIds], reusing
///   `MATRIX_ALWAYS_RESPOND_ROOMS`) so churny bridge portals never trigger it,
/// - [sender] is a real human, not a bridge/relay puppet, and
/// - the (room, sender) pair has not been welcomed before ([alreadyWelcomed]).
///
/// The display name falls back to the MXID localpart only for real users, so a
/// puppet's `pvt pvt` displayname can never surface — puppets are filtered out
/// entirely one step earlier.
String? welcomeMessage({
  required String sender,
  required String roomId,
  required bool isMemberJoin,
  required Set<String> hubRoomIds,
  String? displayName,
  Set<String> bridgeBotIds = const {},
  List<String> selfPuppetIds = const [],
  bool alreadyWelcomed = false,
}) {
  if (!isMemberJoin) return null;
  if (!hubRoomIds.contains(roomId)) return null;
  if (alreadyWelcomed) return null;
  if (isBridgePuppet(
    sender,
    bridgeBotIds: bridgeBotIds,
    selfPuppetIds: selfPuppetIds,
  )) {
    return null;
  }

  final trimmed = displayName?.trim();
  final name = (trimmed != null && trimmed.isNotEmpty)
      ? trimmed
      : sender.split(':').first.substring(1);
  return "Welcome $name! Say 'kickstart' here and I'll walk us through setup. ✨";
}
