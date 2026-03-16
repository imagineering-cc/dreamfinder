/// Matrix authentication — supports access token and password login.
///
/// Two modes:
/// - `MATRIX_ACCESS_TOKEN` — direct token (preferred for bots).
/// - `MATRIX_USERNAME` + `MATRIX_PASSWORD` — login via `POST /v3/login`.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

/// Obtains a Matrix access token, either from a pre-configured value or
/// by logging in with username/password.
class MatrixAuth {
  MatrixAuth({
    required this.homeserver,
    this.accessToken,
    this.username,
    this.password,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String homeserver;
  final String? accessToken;
  final String? username;
  final String? password;
  final http.Client _client;

  String? _cachedToken;

  /// Returns a valid access token.
  ///
  /// If [accessToken] is set, returns it directly. Otherwise, logs in with
  /// [username] and [password] via the Matrix login endpoint.
  ///
  /// Caches the token after first login — Matrix access tokens don't expire
  /// by default for bot accounts.
  Future<String> getAccessToken() async {
    if (accessToken != null && accessToken!.isNotEmpty) return accessToken!;

    if (_cachedToken != null) return _cachedToken!;

    if (username == null || password == null) {
      throw StateError(
        'Matrix auth requires either MATRIX_ACCESS_TOKEN or '
        'MATRIX_USERNAME + MATRIX_PASSWORD',
      );
    }

    final response = await _client.post(
      Uri.parse('$homeserver/_matrix/client/v3/login'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode(<String, dynamic>{
        'type': 'm.login.password',
        'identifier': <String, dynamic>{
          'type': 'm.id.user',
          'user': username,
        },
        'password': password,
      }),
    );

    if (response.statusCode != 200) {
      throw MatrixAuthException(
        statusCode: response.statusCode,
        body: response.body,
      );
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    _cachedToken = json['access_token'] as String;
    return _cachedToken!;
  }
}

/// Exception thrown when Matrix authentication fails.
class MatrixAuthException implements Exception {
  const MatrixAuthException({required this.statusCode, required this.body});

  final int statusCode;
  final String body;

  @override
  String toString() => 'MatrixAuthException($statusCode): $body';
}
