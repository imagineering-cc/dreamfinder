/// Loud escalation when River's brain goes offline.
///
/// The motivating incident: River hit the Anthropic credit-balance wall and
/// silently dropped every message for days — `/health` said `ok` and nobody was
/// alerted. Honest health (see `HealthCheck.recordClaudeError`) makes the
/// failure *visible*; the [Alerter] makes it *loud*.
///
/// On a non-retryable capability failure (`billing`/`auth` that couldn't be
/// recovered by an auth fallback), the alerter fires on two best-effort
/// channels:
///   1. Telegram via the `notify` sidecar (operator alert).
///   2. A short, static, in-character message into the announce room (so the
///      humans in the room know the bot's brain is down — we send a templated
///      message, NOT an agent-composed one, because the brain is what's broken).
///
/// Both channels are wrapped so a failure in one never throws or blocks the
/// other. Alerts are deduplicated per `kind` within a cooldown window so a
/// flapping failure doesn't spam.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../logging/logger.dart';

/// Default cooldown: don't re-alert for the same `kind` within an hour.
const _defaultCooldown = Duration(hours: 1);

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
    DateTime Function()? clock,
  })  : _sendToRoom = sendToRoom,
        _httpClient = httpClient ?? http.Client(),
        _log = log,
        _cooldown = cooldown,
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
  final DateTime Function() _clock;

  /// Last time we alerted for each `kind`, for dedup.
  final Map<String, DateTime> _lastAlertAt = {};

  /// Escalates a non-retryable capability failure of the given [kind]
  /// (`billing`/`auth`/`other`) with a short [message].
  ///
  /// No-ops (logs only) if the same [kind] alerted within the cooldown window.
  Future<void> escalate({
    required String kind,
    required String message,
  }) async {
    final now = _clock();
    final last = _lastAlertAt[kind];
    if (last != null && now.difference(last) < _cooldown) {
      _log?.info('Alert suppressed (within cooldown)', extra: {
        'kind': kind,
        'since_last_seconds': now.difference(last).inSeconds,
      });
      return;
    }
    _lastAlertAt[kind] = now;

    _log?.error('Escalating brain failure', extra: {
      'kind': kind,
      'message': message,
      'auth_mode': authModeLabel,
    });

    // Both channels are best-effort and independent.
    await _alertTelegram(kind, message);
    await _alertInRoom();
  }

  Future<void> _alertTelegram(String kind, String message) async {
    final url = notifyUrl;
    final apiKey = notifyApiKey;
    if (url == null || url.isEmpty || apiKey == null || apiKey.isEmpty) {
      return; // Channel not configured — skip silently.
    }
    final body = '⚠️ River brain offline: $kind — $message. '
        'Auth mode: $authModeLabel.';
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
      }
    } on Object catch (e) {
      _log?.warning('notify alert failed: $e');
    }
  }

  Future<void> _alertInRoom() async {
    final roomId = announceRoomId;
    final send = _sendToRoom;
    if (roomId == null || roomId.isEmpty || send == null) {
      return; // Channel not configured — skip silently.
    }
    try {
      await send(roomId, _inRoomMessage);
    } on Object catch (e) {
      _log?.warning('in-room alert failed: $e');
    }
  }

  /// Static, in-character "brain's gone walkabout" message. Deliberately NOT
  /// agent-composed — the agent is exactly what's broken.
  static const _inRoomMessage =
      "Oi — my brain's gone walkabout. Can't reach Claude right now, so I'm "
      "no good to anyone till it's sorted. Someone poke Nick.";
}
