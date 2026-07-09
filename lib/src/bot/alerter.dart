/// Loud escalation when something River depends on breaks — sharpened by
/// *severity* so the humans hear the difference between a paper cut and a heart
/// attack.
///
/// The motivating incident: River hit the Anthropic credit-balance wall and
/// silently dropped every message for days — `/health` said `ok` and nobody was
/// alerted. Honest health (see `HealthCheck.recordClaudeError`) makes the
/// failure *visible*; the [Alerter] makes it *loud*.
///
/// But not everything worth alerting on is "the brain is offline." A probe that
/// catches River returning forged memory means River is *up* but a capability is
/// lying; an antibody whose recalibration deadline has passed is a maintenance
/// chore, not an emergency. Framing all three identically ("brain offline") is
/// both a lie and how the one real page gets ignored. [AlertSeverity] selects
/// the frame, the channel-set, and the nag cadence — an action's loudness
/// matching the certainty and gravity of what was observed (impedance-match,
/// applied to the alert itself).
///
/// Channels (both best-effort, wrapped so a failure in one never throws or
/// blocks the other):
///   1. Telegram via the `notify` sidecar (operator alert).
///   2. A short, static, in-character message into the announce room — a
///      templated message, NOT an agent-composed one, because the agent may be
///      exactly what's broken. Only severities that the *room* should react to
///      reach this channel; a maintenance nudge stays operator-only.
///
/// Alerts are deduplicated per `kind` within a severity-dependent cooldown so a
/// flapping failure doesn't spam and a standing maintenance condition nags
/// daily rather than hourly.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../logging/logger.dart';

/// Default cooldown for an *urgent* alert (brain-offline / capability failure):
/// don't re-alert for the same `kind` within an hour.
const _defaultCooldown = Duration(hours: 1);

/// Default cooldown for a *maintenance* alert. An expired antibody is a standing
/// condition; nagging hourly is noise, so a lifecycle nudge repeats daily.
const _defaultMaintenanceCooldown = Duration(hours: 24);

/// The gravity of an escalation — selects the human-facing frame, which
/// channels fire, and how often the same `kind` may repeat.
///
/// This is the taxonomy that replaces "everything is brain offline":
enum AlertSeverity {
  /// The agent loop itself is down — the credit-balance wall, an unrecoverable
  /// auth failure, a violated boot invariant. River is genuinely no good to
  /// anyone; the room needs to know. Both channels; urgent cadence.
  brainOffline,

  /// River is *up* but a deterministic self-check caught a capability returning
  /// wrong results (a probe's identity invariant was violated — forged memory,
  /// hollow search). The room should distrust River in that area; the operator
  /// must investigate. Both channels, but an honest frame that does NOT claim
  /// the brain is dead. Urgent cadence.
  capabilityFailure,

  /// A lifecycle event — an antibody's recalibration deadline passed. Nothing is
  /// broken *yet*; the baseline may just be stale. A maintenance nudge for the
  /// operator only, never a room-wide alarm, on a daily cadence.
  maintenance;

  /// Whether this severity is loud enough to earn an interruption of the
  /// community announce room.
  bool get reachesRoom => this != AlertSeverity.maintenance;
}

/// Sends a templated in-room message to [roomId]. Returns when delivered.
typedef RoomSendFn = Future<void> Function(String roomId, String message);

/// Escalates unrecoverable brain failures to humans, with per-kind dedup.
class Alerter {
  Alerter({
    this.notifyUrl,
    this.notifyApiKey,
    this.announceRoomId,
    this.authModeLabel = 'unknown',
    RoomSendFn? sendToRoom,
    http.Client? httpClient,
    BotLogger? log,
    Duration cooldown = _defaultCooldown,
    Duration maintenanceCooldown = _defaultMaintenanceCooldown,
    DateTime Function()? clock,
  })  : _sendToRoom = sendToRoom,
        _httpClient = httpClient ?? http.Client(),
        _log = log,
        _cooldown = cooldown,
        _maintenanceCooldown = maintenanceCooldown,
        _clock = clock ?? DateTime.now;

  /// `notify` sidecar base URL (e.g. `http://host.docker.internal:8090`).
  /// If null, the Telegram channel is skipped.
  final String? notifyUrl;

  /// Bearer token for the `notify` sidecar. If null, Telegram is skipped.
  final String? notifyApiKey;

  /// Room to drop the in-character "brain offline" message into. If null, the
  /// in-room channel is skipped.
  final String? announceRoomId;

  /// Human-readable current auth mode (e.g. `OAuth (Claude Max)`,
  /// `API key`, `API key (OAuth fallback)`), surfaced in the operator alert.
  ///
  /// Mutable so the entry point can update it when River falls back from OAuth
  /// to the API key mid-flight.
  String authModeLabel;

  final RoomSendFn? _sendToRoom;
  final http.Client _httpClient;
  final BotLogger? _log;
  final Duration _cooldown;
  final Duration _maintenanceCooldown;
  final DateTime Function() _clock;

  /// Last time we alerted for each `kind`, for dedup.
  final Map<String, DateTime> _lastAlertAt = {};

  /// Escalates a failure of the given [kind] with a short [message], framed by
  /// [severity].
  ///
  /// The `kind` is the dedup key (e.g. `billing`, `probe_content_integrity`,
  /// `expired::probe_calendar`). The [severity] selects the human-facing frame,
  /// which channels fire, and the cooldown window. Defaults to
  /// [AlertSeverity.brainOffline] so pre-severity callers keep their behaviour.
  ///
  /// No-ops (logs only) if the same [kind] alerted within its cooldown window.
  Future<void> escalate({
    required String kind,
    required String message,
    AlertSeverity severity = AlertSeverity.brainOffline,
  }) async {
    final now = _clock();
    final cooldown = _cooldownFor(severity);
    final last = _lastAlertAt[kind];
    if (last != null && now.difference(last) < cooldown) {
      _log?.info('Alert suppressed (within cooldown)', extra: {
        'kind': kind,
        'severity': severity.name,
        'since_last_seconds': now.difference(last).inSeconds,
      });
      return;
    }

    // NOTE: dedup is keyed by `kind` alone, not `(kind, severity)`. Current
    // callers namespace maintenance separately (`expired::<id>` vs a probe's
    // bare `r.id` vs `billing`/`auth`), so a low-severity page can never suppress
    // an urgent one. If a future caller reuses a `kind` across severities, this
    // invariant breaks — key by `(kind, severity)` then. (Carnot/Tesla, PR2c.)

    // Match the log level to the severity: a maintenance nudge is not an error,
    // and logging it as one just rebuilds the alert fatigue we cured on the
    // Telegram side inside the observability layer (Tesla, PR2c review). The
    // brainOffline message string is preserved verbatim so log/pager scrapes
    // keyed on it don't detune.
    final logExtra = <String, Object?>{
      'kind': kind,
      'severity': severity.name,
      'message': message,
      'auth_mode': authModeLabel,
    };
    switch (severity) {
      case AlertSeverity.brainOffline:
        _log?.error('Escalating brain failure', extra: logExtra);
      case AlertSeverity.capabilityFailure:
        _log?.error('Escalating capability failure', extra: logExtra);
      case AlertSeverity.maintenance:
        _log?.warning('Escalating maintenance alert', extra: logExtra);
    }

    // Both channels are best-effort and independent. The room only fires for
    // severities loud enough to earn it.
    final telegramDelivered = await _alertTelegram(kind, message, severity);
    var roomDelivered = false;
    if (severity.reachesRoom) {
      roomDelivered = await _alertInRoom(severity);
    }

    // Stamp the cooldown only on SUCCESSFUL delivery to at least one channel. A
    // rate-limit lease must be earned by a page that actually landed, not by the
    // intent to page — otherwise a failed first send (sidecar cold, 5xx) burns
    // the whole cooldown and the operator hears silence, worst of all for the
    // 24h maintenance window. On total delivery failure we leave the key unset
    // so the next tick retries. (Carnot blocker / Tesla, PR2c review.)
    //
    // NB: this dedup is process-local, so a standing maintenance condition still
    // re-pages once per process restart regardless of the window — the durable
    // cross-restart cadence (persist to bot_metadata) is deferred to task #41.
    if (telegramDelivered || roomDelivered) {
      _lastAlertAt[kind] = now;
    } else {
      _log?.warning('Alert not delivered on any channel; cooldown not stamped',
          extra: {'kind': kind, 'severity': severity.name});
    }
  }

  /// The cooldown window for [severity]: urgent alerts repeat hourly, a standing
  /// maintenance condition daily.
  Duration _cooldownFor(AlertSeverity severity) =>
      severity == AlertSeverity.maintenance ? _maintenanceCooldown : _cooldown;

  /// The operator-facing (Telegram) frame for [severity]. Named honestly so a
  /// capability failure is not miscalled a dead brain.
  String _telegramBody(String kind, String message, AlertSeverity severity) {
    switch (severity) {
      case AlertSeverity.brainOffline:
        return '⚠️ River brain offline: $kind — $message. '
            'Auth mode: $authModeLabel.';
      case AlertSeverity.capabilityFailure:
        return '⚠️ River capability failure: $kind — $message. '
            'River is up but this capability is returning wrong results.';
      case AlertSeverity.maintenance:
        return '🔧 River maintenance: $kind — $message. '
            'Nothing is down; an antibody needs recalibration.';
    }
  }

  /// Returns true iff the alert was delivered (a 2xx from the sidecar). A
  /// not-configured channel, a non-2xx, or a thrown error all return false so
  /// [escalate] can withhold the cooldown stamp until a page actually lands.
  Future<bool> _alertTelegram(
      String kind, String message, AlertSeverity severity) async {
    final url = notifyUrl;
    final apiKey = notifyApiKey;
    if (url == null || url.isEmpty || apiKey == null || apiKey.isEmpty) {
      return false; // Channel not configured — nothing delivered.
    }
    final body = _telegramBody(kind, message, severity);
    try {
      final response = await _httpClient.post(
        Uri.parse('$url/send'),
        headers: {
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(<String, Object?>{
          'message': body,
          'parse_mode': null,
        }),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        _log?.warning('notify alert non-2xx', extra: {
          'status': response.statusCode,
        });
        return false;
      }
      return true;
    } on Object catch (e) {
      _log?.warning('notify alert failed: $e');
      return false;
    }
  }

  /// Returns true iff the in-room message was sent without throwing. A
  /// not-configured room or a send failure returns false (see [_alertTelegram]).
  Future<bool> _alertInRoom(AlertSeverity severity) async {
    assert(severity.reachesRoom,
        'in-room alert requested for $severity, which does not reach the room');
    final roomId = announceRoomId;
    final send = _sendToRoom;
    if (roomId == null || roomId.isEmpty || send == null) {
      return false; // Channel not configured — nothing delivered.
    }
    try {
      await send(roomId, _inRoomMessage(severity));
      return true;
    } on Object catch (e) {
      _log?.warning('in-room alert failed: $e');
      return false;
    }
  }

  /// Static, in-character room message for [severity]. Deliberately NOT
  /// agent-composed — the agent may be exactly what's broken.
  ///
  /// The capability-failure copy is deliberately *subsystem-agnostic*: a
  /// capability failure fires from any of the immune probes (content, calendar,
  /// search, auth), so naming one — e.g. "my memory" — would tell the room a
  /// failure mode the probe did not actually observe. That is the exact lie this
  /// PR exists to kill, one grain finer; keep it generic (Tesla, PR2c review).
  String _inRoomMessage(AlertSeverity severity) {
    switch (severity) {
      case AlertSeverity.brainOffline:
        return "Oi — my brain's gone walkabout. Can't reach Claude right now, "
            "so I'm no good to anyone till it's sorted. Someone poke Nick.";
      case AlertSeverity.capabilityFailure:
        return 'Heads up — one of my self-checks just failed, so I might be '
            "off the mark on something till it's looked at. Don't take my word "
            'as gospel for now. Poke Nick.';
      case AlertSeverity.maintenance:
        // Unreachable: escalate() gates maintenance out of the room via
        // reachesRoom, and _alertInRoom asserts it. Fail loud (caught by the
        // best-effort wrapper in _alertInRoom) rather than posting silence to
        // the room if a future edit ever routes maintenance here.
        throw StateError('maintenance severity has no room message');
    }
  }
}
