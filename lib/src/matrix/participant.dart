/// One authoritative answer to "what kind of participant is this MXID?".
///
/// This replaces three scattered string-match lists (`nonHumanMxidPrefixes`,
/// `bridgeBotIds`, `selfPuppetIds`) that each consumer combined ad-hoc. The
/// human/non-human distinction was enforced by a bare `startsWith` prefix scan
/// in three places — adding a bridge meant hand-editing a list, and a single
/// mis-scoped prefix (`@signal_` read as a bot instead of a person) once made
/// the welcome filter greet *nobody*. Classification is still prefix-based (a
/// homeserver exposes no cleaner authority at runtime), but it now happens in
/// ONE typed place every consumer routes through: the catastrophe is a single
/// reviewable decision instead of three scattered scans that could silently
/// disagree — not "impossible", but no longer able to hide.
///
/// TOPOLOGY (verified against the live prod mautrix registrations, 2026-08-10):
/// each bridge registration exposes exactly two namespaces —
///   `@<id>bot:<domain>`  → the bridge BOT (an appservice sender, non-human)
///   `@<id>_.*:<domain>`   → the per-user PUPPETS, which ARE the bridged people.
/// So `@signal_<uuid>` is a human; `@signalbot:` is not. The superbridge relay
/// adds `@_relay_…` puppets, and River itself (+ its own relayed puppets) is
/// self. Everything else is a native Matrix human.
library;

/// What a Matrix participant *is*, structurally — not a string prefix.
enum ParticipantKind {
  /// A real person: a native Matrix user OR a bridged per-user puppet
  /// (`@signal_<uuid>`, `@whatsapp_…`, …). The default for anything unmatched.
  human,

  /// A mautrix bridge appservice bot (`@signalbot:`, `@whatsappbot:`, …) — the
  /// sender the bridge itself posts as. Not a person.
  bridgeBot,

  /// A superbridge relay puppet (`@_relay_…`) that is NOT one of River's own.
  relayPuppet,

  /// River itself: its native MXID or one of its own relayed/bridged puppets.
  /// Used to drop self-echoes the relay reflects back into the hub, which would
  /// otherwise create a response feedback loop.
  self,
}

/// Default bridge-bot MXID prefixes, from the live prod registrations. An
/// operator adds a new bridge's *bot* prefix via `WELCOME_NON_HUMAN_PREFIXES`
/// (fed into [ParticipantClassifier.new]'s `bridgeBotPrefixes`) without a code
/// deploy. `@slackbot:` is included defensively.
///
/// NEVER add a per-user bridged namespace (`@signal_`, `@whatsapp_`, …) here:
/// those match real community members, and marking them non-human is exactly
/// the "welcome nobody" catastrophe. Bridge BOTS end in `bot:`; puppets are
/// `@<platform>_<id>` — keep only the former.
const defaultBridgeBotPrefixes = <String>[
  '@signalbot:',
  '@whatsappbot:',
  '@telegrambot:',
  '@discordbot:',
  '@slackbot:',
];

/// Default relay-puppet prefix (the superbridge relay appservice namespace).
const defaultRelayPrefixes = <String>['@_relay_'];

/// Classifies a Matrix user id into exactly one [ParticipantKind].
///
/// Precedence is total and ordered — [self] first, then [bridgeBot], then
/// [relayPuppet], then [human] — so an id that could match more than one rule
/// resolves deterministically. Self is first on purpose: one of River's own
/// puppets can sit inside the `@_relay_` namespace, and misreading it as a
/// relay puppet (rather than self) is exactly the self-echo loop this guards.
class ParticipantClassifier {
  ParticipantClassifier({
    required this.botUserId,
    Set<String> selfPuppetIds = const {},
    Set<String> bridgeBotIds = const {},
    List<String> bridgeBotPrefixes = defaultBridgeBotPrefixes,
    List<String> relayPrefixes = defaultRelayPrefixes,
  })  : _selfPuppetIds = selfPuppetIds,
        _bridgeBotIds = bridgeBotIds,
        _bridgeBotPrefixes = bridgeBotPrefixes,
        _relayPrefixes = relayPrefixes;

  /// River's own native MXID.
  final String botUserId;
  final Set<String> _selfPuppetIds;
  final Set<String> _bridgeBotIds;
  final List<String> _bridgeBotPrefixes;
  final List<String> _relayPrefixes;

  /// The single door: every consumer routes MXID classification through here.
  ParticipantKind classify(String mxid) {
    // self — checked FIRST (precedence): River's native id or its own puppets.
    if (mxid == botUserId || _selfPuppetIds.contains(mxid)) {
      return ParticipantKind.self;
    }
    // bridgeBot — explicit ids, then the appservice bot prefixes.
    if (_bridgeBotIds.contains(mxid) || _hasPrefix(mxid, _bridgeBotPrefixes)) {
      return ParticipantKind.bridgeBot;
    }
    // relayPuppet — relay namespace, but NOT one of River's own (caught above).
    if (_hasPrefix(mxid, _relayPrefixes)) {
      return ParticipantKind.relayPuppet;
    }
    // human — native users AND bridged per-user puppets (@signal_<uuid> …),
    // AND any malformed/non-MXID sender (fail safe: never self or a bot).
    return ParticipantKind.human;
  }

  /// True when [mxid] is River itself or one of its own puppets.
  bool isSelf(String mxid) => classify(mxid) == ParticipantKind.self;

  /// True when [mxid] is a real person (the only kind River welcomes / counts).
  bool isHuman(String mxid) => classify(mxid) == ParticipantKind.human;

  /// True when [mxid] is a mautrix bridge appservice bot. This is a KIND
  /// predicate only — it says what the participant *is*, NOT that it is trusted
  /// for any purpose. Relay/permalink trust is a separate, per-platform concern
  /// owned by messaging_tools (a Telegram-room reply is only authoritative from
  /// the *Telegram* bot); do not fold that into this coarse kind check.
  bool isBridgeBot(String mxid) => classify(mxid) == ParticipantKind.bridgeBot;

  static bool _hasPrefix(String mxid, List<String> prefixes) =>
      prefixes.any(mxid.startsWith);
}
