/// LiveKit server-side client for sending data to rooms via the Twirp RPC API.
///
/// Uses the `RoomService/SendData` endpoint to publish messages without
/// joining as a WebRTC participant. Authentication via HS256 JWT.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// Data delivery mode for LiveKit data channels.
enum DataKind {
  /// Guaranteed delivery, ordered (SCTP).
  reliable,

  /// Best-effort delivery, lower latency.
  lossy;

  /// Protobuf JSON enum name.
  String get protoName => switch (this) {
        reliable => 'RELIABLE',
        lossy => 'LOSSY',
      };
}

/// Exception thrown when the LiveKit API returns a non-200 response.
class LiveKitApiException implements Exception {
  LiveKitApiException(this.statusCode, this.body);

  final int statusCode;
  final String body;

  @override
  String toString() => 'LiveKitApiException($statusCode): $body';
}

/// Client for LiveKit's server-side Twirp RPC API.
///
/// Sends data to rooms via `POST /twirp/livekit.RoomService/SendData`.
/// Does not require WebRTC — pure HTTP.
class LiveKitServerClient {
  LiveKitServerClient({
    required String serverUrl,
    required String apiKey,
    required String apiSecret,
    http.Client? httpClient,
    Duration tokenTtl = const Duration(minutes: 10),
  })  : _serverUrl = _normalizeUrl(serverUrl),
        _apiKey = apiKey,
        _apiSecret = apiSecret,
        _httpClient = httpClient ?? http.Client(),
        _ownsClient = httpClient == null,
        _tokenTtl = tokenTtl;

  /// Normalizes a LiveKit server URL for HTTP API access.
  ///
  /// Converts `wss://` to `https://` (the Twirp API uses HTTP, not WebSocket)
  /// and strips trailing slashes.
  static String _normalizeUrl(String url) {
    var normalized = url;
    if (normalized.startsWith('wss://')) {
      normalized = 'https://${normalized.substring(6)}';
    } else if (normalized.startsWith('ws://')) {
      normalized = 'http://${normalized.substring(5)}';
    }
    if (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  final String _serverUrl;
  final String _apiKey;
  final String _apiSecret;
  final http.Client _httpClient;
  final bool _ownsClient;
  final Duration _tokenTtl;

  // Cached token and its expiry.
  String? _cachedToken;
  DateTime? _tokenExpiry;

  /// Sends raw bytes to a LiveKit room on the given [topic].
  ///
  /// Optionally target specific participants via [destinationIdentities].
  /// Defaults to [DataKind.reliable] delivery.
  Future<void> sendData({
    required String room,
    required List<int> data,
    required String topic,
    List<String>? destinationIdentities,
    DataKind kind = DataKind.reliable,
  }) async {
    final token = _getOrRefreshToken();
    final uri =
        Uri.parse('$_serverUrl/twirp/livekit.RoomService/SendData');

    final body = <String, Object?>{
      'room': room,
      'data': base64Encode(data),
      'kind': kind.protoName,
      'topic': topic,
    };

    if (destinationIdentities != null) {
      body['destination_identities'] = destinationIdentities;
    }

    final response = await _httpClient.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode(body),
    );

    if (response.statusCode != 200) {
      throw LiveKitApiException(response.statusCode, response.body);
    }
  }

  /// Convenience: encodes a JSON map and sends it as data.
  Future<void> sendJson({
    required String room,
    required String topic,
    required Map<String, Object?> payload,
    List<String>? destinationIdentities,
    DataKind kind = DataKind.reliable,
  }) =>
      sendData(
        room: room,
        data: utf8.encode(jsonEncode(payload)),
        topic: topic,
        destinationIdentities: destinationIdentities,
        kind: kind,
      );

  /// Releases resources.
  void close() {
    if (_ownsClient) _httpClient.close();
  }

  /// Returns a cached JWT or generates a fresh one.
  String _getOrRefreshToken() {
    final now = DateTime.now();
    if (_cachedToken != null &&
        _tokenExpiry != null &&
        now.isBefore(_tokenExpiry!.subtract(const Duration(seconds: 30)))) {
      return _cachedToken!;
    }

    _cachedToken = _generateJwt(now);
    _tokenExpiry = now.add(_tokenTtl);
    return _cachedToken!;
  }

  /// Generates an HS256 JWT for the LiveKit RoomService API.
  String _generateJwt(DateTime now) {
    final header = _base64UrlEncode(
      jsonEncode({'alg': 'HS256', 'typ': 'JWT'}),
    );

    final nbf = now.millisecondsSinceEpoch ~/ 1000;
    final exp = nbf + _tokenTtl.inSeconds;

    final payload = _base64UrlEncode(
      jsonEncode(<String, Object?>{
        'iss': _apiKey,
        'nbf': nbf,
        'exp': exp,
        'video': {'roomAdmin': true},
      }),
    );

    final signingInput = '$header.$payload';
    final hmac = Hmac(sha256, utf8.encode(_apiSecret));
    final digest = hmac.convert(utf8.encode(signingInput));
    final signature = _base64UrlEncodeBytes(digest.bytes);

    return '$signingInput.$signature';
  }

  static String _base64UrlEncode(String input) =>
      _base64UrlEncodeBytes(utf8.encode(input));

  static String _base64UrlEncodeBytes(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');
}
