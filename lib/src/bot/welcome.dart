/// Deciding whether — and how — to welcome a member who joined a room.
///
/// Extracted from the main loop so the decision is unit-testable in isolation
/// (the inline version welcomed every membership event, including bridge
/// puppets, producing repeating "Welcome pvt pvt!" spam).
library;

/// MXID prefixes for members River must NOT welcome — the true non-humans.
///
/// CRITICAL TOPOLOGY NOTE (verified against the live prod hub, 2026-08-02):
/// in the superbridge setup, real community members are bridged into the
/// Matrix hub and therefore carry the per-user appservice namespaces
/// `@signal_<uuid>`, `@whatsapp_<…>`, `@telegram_<…>`. Those ARE the people
/// River should welcome — they must never be filtered. The only members that
/// are not people are:
///   - the superbridge relay puppets (`@_relay_…`),
///   - the mautrix bridge BOTS (`@signalbot:…`, `@whatsappbot:…`, …), and
///   - River itself (`@dreamfinder-bot:…`).
/// The `pvt pvt` spam was one of these bridged HUMANS whose Signal contact
/// name hadn't resolved yet, welcomed repeatedly on resync — a name-resolution
/// + dedup problem, not a "puppet" problem. So the fix is dedup + hub-scope,
/// and this list filters only the genuine non-humans.
const puppetMxidPrefixes = <String>[
  '@_relay_',
  '@signalbot:',
  '@whatsappbot:',
  '@telegrambot:',
  '@discordbot:',
  '@slackbot:',
  '@dreamfinder-bot:',
];

/// Returns `true` if [sender] is a bridge/relay puppet rather than a real user.
///
/// Checks, in order: the explicit bridge bot MXIDs ([bridgeBotIds]), River's
/// own relayed puppets ([selfPuppetIds]), then the appservice namespace
/// prefixes ([prefixes], defaulting to [puppetMxidPrefixes] — an operator can
/// override via `WELCOME_PUPPET_PREFIXES` to correct a namespace drift without
/// a code deploy).
bool isBridgePuppet(
  String sender, {
  Set<String> bridgeBotIds = const {},
  List<String> selfPuppetIds = const [],
  List<String> prefixes = puppetMxidPrefixes,
}) {
  if (bridgeBotIds.contains(sender)) return true;
  if (selfPuppetIds.contains(sender)) return true;
  for (final prefix in prefixes) {
    if (sender.startsWith(prefix)) return true;
  }
  return false;
}

/// Longest display name we'll echo into a room. A bridge or a hostile client
/// can set an arbitrarily long displayname; without a cap it becomes a
/// multi-kilobyte billboard in the welcome. Real names are far shorter.
const _maxWelcomeNameLength = 80;

/// Neutralises a room-bound display name so a joining member can't shape
/// River's welcome: replaces control characters (C0/C1/DEL) and
/// bidirectional-override codepoints with spaces, then collapses whitespace
/// runs to a single space. Without this, a name containing newlines or bidi
/// controls could make River post a multi-line, system-looking welcome
/// (Carnot, cage-match PR #126). Codepoint-based rather than a regex with
/// literal control chars in source.
String _sanitizeName(String name) {
  final buf = StringBuffer();
  for (final rune in name.runes) {
    final isC0OrDel = rune < 0x20 || rune == 0x7f;
    final isC1 = rune >= 0x80 && rune <= 0x9f;
    final isBidi = rune == 0x200e ||
        rune == 0x200f ||
        (rune >= 0x202a && rune <= 0x202e) ||
        (rune >= 0x2066 && rune <= 0x2069);
    buf.writeCharCode((isC0OrDel || isC1 || isBidi) ? 0x20 : rune);
  }
  return buf.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// A safe, human-facing label for [sender], never throwing on malformed input.
///
/// Matrix MXIDs are `@localpart:server`, but membership events cross the
/// untrusted homeserver/bridge boundary — an empty or non-`@` sender must not
/// RangeError the sync loop (Carnot + Tesla, cage-match PR #126). Falls back to
/// the raw sender when it isn't MXID-shaped.
String _fallbackLabel(String sender) {
  if (sender.startsWith('@') && sender.length > 1) {
    return sender.substring(1).split(':').first;
  }
  return sender;
}

/// The `bot_metadata` dedup key for a welcomed (room, sender) pair.
///
/// Persisting this means a bridge resync that re-emits an old join — or River
/// restarting — never re-welcomes someone already greeted. This is
/// intentionally once-per-(room, sender)-forever: a genuine leave→rejoin is
/// not re-welcomed. That's the correct trade to kill resync spam; if
/// per-stint re-onboarding is ever wanted, add a membership-generation
/// component to the key rather than a TTL (Tesla, cage-match PR #126).
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
/// [alreadyWelcomed] is a lazy thunk, evaluated only *after* the cheap join /
/// hub / puppet gates pass — so a bridge resync storm (of puppets, or into a
/// non-hub portal) never triggers the backing `bot_metadata` read (Tesla,
/// cage-match PR #126). Defaults to "not welcomed".
///
/// The display name is sanitised and length-capped, and falls back to the MXID
/// localpart only for real users — a puppet's `pvt pvt` displayname can never
/// surface, since puppets are filtered out entirely one step earlier.
String? welcomeMessage({
  required String sender,
  required String roomId,
  required bool isMemberJoin,
  required Set<String> hubRoomIds,
  String? displayName,
  Set<String> bridgeBotIds = const {},
  List<String> selfPuppetIds = const [],
  List<String> puppetPrefixes = puppetMxidPrefixes,
  bool Function()? alreadyWelcomed,
}) {
  if (!isMemberJoin) return null;
  if (!hubRoomIds.contains(roomId)) return null;
  if (isBridgePuppet(
    sender,
    bridgeBotIds: bridgeBotIds,
    selfPuppetIds: selfPuppetIds,
    prefixes: puppetPrefixes,
  )) {
    return null;
  }
  // Expensive gate last: only now (real human, hub room) do we consult the
  // dedup store.
  if (alreadyWelcomed != null && alreadyWelcomed()) return null;

  final cleaned = displayName == null ? '' : _sanitizeName(displayName);
  var name = cleaned.isNotEmpty ? cleaned : _fallbackLabel(sender);
  // Truncate on rune boundaries, not UTF-16 code units, so an emoji or
  // surrogate pair can't be split into mojibake at the cap (Tesla, PR #126).
  final runes = name.runes.toList();
  if (runes.length > _maxWelcomeNameLength) {
    name = '${String.fromCharCodes(runes.take(_maxWelcomeNameLength))}…';
  }
  return "Welcome $name! Say 'kickstart' here and I'll walk us through setup. ✨";
}
