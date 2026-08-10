/// Deciding whether — and how — to welcome a member who joined a room.
///
/// Extracted from the main loop so the decision is unit-testable in isolation
/// (the inline version welcomed every membership event in any room, with no
/// dedup — so a bridged member whose name hadn't resolved was greeted as
/// "Welcome pvt pvt!" repeatedly on every bridge resync).
///
/// Who-is-a-person is decided by a single [ParticipantClassifier]
/// (`lib/src/matrix/participant.dart`) — the one authoritative MXID→kind
/// mapping. Bridged community members (`@signal_<uuid>` …) classify as
/// [ParticipantKind.human] and ARE welcomed; only bridge bots, relay puppets,
/// and River itself are filtered.
library;

import '../matrix/participant.dart';

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
/// - [sender] classifies as [ParticipantKind.human] via [classifier] (bridged
///   community members ARE people; only bots / relay puppets / self are not),
///   and
/// - the (room, sender) pair has not been welcomed before ([alreadyWelcomed]).
///
/// [alreadyWelcomed] is a lazy thunk, evaluated only *after* the cheap join /
/// hub / non-human gates pass — so a resync storm (bots, or joins into a
/// non-hub portal) never triggers the backing `bot_metadata` read (Tesla,
/// cage-match PR #126). Defaults to "not welcomed".
///
/// The display name is sanitised and length-capped, and falls back to the MXID
/// localpart when blank. An unresolved bridged name (the `pvt pvt` case) is
/// welcomed once, as-is — dedup makes it one-time (Nick's call, PR #126).
String? welcomeMessage({
  required String sender,
  required String roomId,
  required bool isMemberJoin,
  required Set<String> hubRoomIds,
  required ParticipantClassifier classifier,
  String? displayName,
  bool Function()? alreadyWelcomed,
}) {
  if (!isMemberJoin) return null;
  if (!hubRoomIds.contains(roomId)) return null;
  // Only real people get welcomed — the single classifier owns this decision.
  if (classifier.classify(sender) != ParticipantKind.human) return null;
  // Expensive gate last: only now (real human, hub room) do we consult the
  // dedup store.
  if (alreadyWelcomed != null && alreadyWelcomed()) return null;

  // Sanitize the CHOSEN name uniformly — both the displayname and the MXID
  // fallback cross the untrusted homeserver/bridge boundary, so control/bidi
  // chars must be stripped from whichever we use (Carnot, cage-match PR #126).
  final fromDisplay = displayName == null ? '' : _sanitizeName(displayName);
  var name = fromDisplay.isNotEmpty
      ? fromDisplay
      : _sanitizeName(_fallbackLabel(sender));
  if (name.isEmpty) name = 'there';
  // Truncate on rune boundaries, not UTF-16 code units, so an emoji or
  // surrogate pair can't be split into mojibake at the cap (Tesla, PR #126).
  final runes = name.runes;
  if (runes.length > _maxWelcomeNameLength) {
    name = '${String.fromCharCodes(runes.take(_maxWelcomeNameLength))}…';
  }
  return "Welcome $name! Say 'kickstart' here and I'll walk us through setup. ✨";
}
