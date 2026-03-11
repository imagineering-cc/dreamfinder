/// OAuth-based Anthropic client using Claude Max refresh tokens.
///
/// Mirrors the approach used by Gremlin (xdeca-pm-bot). Uses the Claude Code
/// CLI's OAuth client ID to exchange a refresh token for short-lived access
/// tokens. Refresh tokens are **single-use** — each refresh returns a new one
/// that must be persisted to survive restarts.
///
/// Token lookup priority: in-memory → SQLite → `CLAUDE_REFRESH_TOKEN` env var.
///
/// State is intentionally lost on restart except for the DB-persisted refresh
/// token. The access token is re-derived on first request.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../db/queries.dart';
import '../logging/logger.dart';

const _tokenUrl = 'https://api.anthropic.com/v1/oauth/token';
const _clientId = '9d1c250a-e61b-44d9-88ed-5944d1962f5e'; // Claude Code CLI

/// Buffer before expiry at which we proactively refresh (1 hour).
const _refreshBuffer = Duration(hours: 1);

/// Health status of the OAuth token.
enum TokenHealthStatus { healthy, expired, error, unknown }

/// Diagnostic snapshot of the current token state.
class TokenHealth {
  const TokenHealth({
    required this.status,
    this.lastRefresh,
    this.expiresAt,
    this.error,
  });

  final TokenHealthStatus status;
  final DateTime? lastRefresh;
  final DateTime? expiresAt;
  final String? error;

  Map<String, Object?> toJson() => {
        'status': status.name,
        'last_refresh': lastRefresh?.toUtc().toIso8601String(),
        'expires_at': expiresAt?.toUtc().toIso8601String(),
        if (error != null) 'error': error,
      };
}

/// Manages OAuth access tokens for the Anthropic API using Claude Max
/// refresh token rotation.
class OAuthTokenManager {
  OAuthTokenManager({
    required Queries queries,
    required BotLogger log,
    String? initialRefreshToken,
    http.Client? httpClient,
  })  : _queries = queries,
        _log = log,
        _envRefreshToken = initialRefreshToken,
        _httpClient = httpClient ?? http.Client();

  final Queries _queries;
  final BotLogger _log;
  final String? _envRefreshToken;
  final http.Client _httpClient;

  String? _currentRefreshToken;
  String? _accessToken;
  DateTime _expiresAt = DateTime(0);
  DateTime? _lastRefresh;
  String? _lastError;

  /// Returns the current token health for diagnostics / health check.
  TokenHealth get health {
    if (_lastError != null) {
      return TokenHealth(
        status: TokenHealthStatus.error,
        lastRefresh: _lastRefresh,
        expiresAt: _expiresAt,
        error: _lastError,
      );
    }
    if (_lastRefresh == null) {
      return const TokenHealth(status: TokenHealthStatus.unknown);
    }
    if (DateTime.now().isAfter(_expiresAt)) {
      return TokenHealth(
        status: TokenHealthStatus.expired,
        lastRefresh: _lastRefresh,
        expiresAt: _expiresAt,
      );
    }
    return TokenHealth(
      status: TokenHealthStatus.healthy,
      lastRefresh: _lastRefresh,
      expiresAt: _expiresAt,
    );
  }

  /// Returns a valid access token, refreshing if necessary.
  ///
  /// Throws on failure (network error, auth error, no refresh token).
  Future<String> getAccessToken() async {
    // Return cached token if still valid (with buffer).
    if (_accessToken != null &&
        DateTime.now().isBefore(_expiresAt.subtract(_refreshBuffer))) {
      return _accessToken!;
    }

    // Resolve refresh token: in-memory → DB → env var.
    var refreshToken = _currentRefreshToken;
    if (refreshToken == null) {
      try {
        refreshToken = _queries.getOAuthToken('claude_refresh');
      } on Exception catch (e) {
        _log.warning('Failed to read refresh token from DB: $e');
      }
    }
    refreshToken ??= _envRefreshToken;

    if (refreshToken == null) {
      const msg =
          'No refresh token available (checked DB and CLAUDE_REFRESH_TOKEN)';
      _lastError = msg;
      throw StateError(msg);
    }

    // Exchange refresh token for a new access token.
    final http.Response response;
    try {
      response = await _httpClient.post(
        Uri.parse(_tokenUrl),
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8',
        },
        body: Uri(queryParameters: {
          'grant_type': 'refresh_token',
          'refresh_token': refreshToken,
          'client_id': _clientId,
        }).query,
      );
    } on Exception catch (e) {
      final msg = 'OAuth token refresh network error: $e';
      _log.error(msg);
      _lastError = msg;
      rethrow;
    }

    if (response.statusCode != 200) {
      final body = response.body.length > 200
          ? '${response.body.substring(0, 200)}...'
          : response.body;
      final msg =
          'OAuth token refresh failed (${response.statusCode}): $body';
      _log.error(msg);
      _lastError = msg;
      throw StateError(msg);
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final accessToken = data['access_token'] as String;
    final newRefreshToken = data['refresh_token'] as String;
    final expiresIn = data['expires_in'] as int; // seconds

    _accessToken = accessToken;
    _expiresAt = DateTime.now().add(Duration(seconds: expiresIn));
    _currentRefreshToken = newRefreshToken;
    _lastRefresh = DateTime.now();
    _lastError = null;

    // Persist the new single-use refresh token to DB immediately.
    try {
      _queries.saveOAuthToken(
        'claude_refresh',
        newRefreshToken,
        expiresAt: _expiresAt.millisecondsSinceEpoch,
      );
    } on Exception catch (e) {
      _log.warning('Failed to persist refresh token to DB: $e');
    }

    _log.info('OAuth token refreshed', extra: {
      'expires_in_hours': (expiresIn / 3600).round(),
    });

    return accessToken;
  }

  /// Invalidates the cached access token, forcing a refresh on next call.
  void invalidate() {
    _accessToken = null;
    _expiresAt = DateTime(0);
  }
}
