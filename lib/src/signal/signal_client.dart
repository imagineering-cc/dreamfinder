import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

/// HTTP client wrapper for the signal-cli-rest-api.
///
/// Accepts an injectable [http.Client] for testability.
class SignalClient {
  SignalClient({
    required this.baseUrl,
    required this.phoneNumber,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String baseUrl;
  final String phoneNumber;
  final http.Client _client;

  static const _jsonHeaders = <String, String>{
    'Content-Type': 'application/json',
  };

  /// Returns API version and build info. `GET /v1/about`
  Future<SignalAbout> about() async {
    final response = await _client.get(Uri.parse('$baseUrl/v1/about'));
    _ensureSuccess(response);
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return SignalAbout.fromJson(json);
  }

  /// Returns registered phone numbers. `GET /v1/accounts`
  Future<List<String>> listAccounts() async {
    final response = await _client.get(Uri.parse('$baseUrl/v1/accounts'));
    _ensureSuccess(response);
    final list = jsonDecode(response.body) as List<dynamic>;
    return list.cast<String>();
  }

  /// Sends a text message to a user or group. `POST /v2/send`
  ///
  /// If [recipient] looks like a phone number (starts with '+') it is sent
  /// as-is. Otherwise it is treated as a base64 group ID and prefixed with
  /// `group.` for the signal-cli-rest-api.
  Future<SendMessageResponse> sendMessage({
    required String recipient,
    required String message,
  }) async {
    final formattedRecipient =
        recipient.startsWith('+') ? recipient : 'group.$recipient';
    final body = <String, dynamic>{
      'message': message,
      'number': phoneNumber,
      'text_mode': 'normal',
      'recipients': <String>[formattedRecipient],
    };
    final response = await _client.post(
      Uri.parse('$baseUrl/v2/send'),
      headers: _jsonHeaders,
      body: jsonEncode(body),
    );
    _ensureSuccess(response, expectedStatus: 201);
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return SendMessageResponse.fromJson(json);
  }

  /// Returns all groups the bot's number is a member of.
  /// `GET /v1/groups/{number}`
  Future<List<SignalGroup>> listGroups() async {
    final response = await _client.get(
      Uri.parse('$baseUrl/v1/groups/$phoneNumber'),
    );
    _ensureSuccess(response);
    final list = jsonDecode(response.body) as List<dynamic>;
    return list
        .map((e) => SignalGroup.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Polls for new messages. `GET /v1/receive/{number}`
  Future<List<SignalEnvelope>> receiveMessages() async {
    final response = await _client.get(
      Uri.parse('$baseUrl/v1/receive/$phoneNumber'),
    );
    _ensureSuccess(response);
    final list = jsonDecode(response.body) as List<dynamic>;
    return list
        .map((e) => SignalEnvelope.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Sends a typing indicator. `PUT /v1/typing-indicator/{number}`
  Future<void> sendTypingIndicator({required String recipient}) async {
    await _client.put(
      Uri.parse('$baseUrl/v1/typing-indicator/$phoneNumber'),
      headers: _jsonHeaders,
      body: jsonEncode(<String, String>{'recipient': recipient}),
    );
  }

  void _ensureSuccess(http.Response response, {int expectedStatus = 200}) {
    if (response.statusCode != expectedStatus) {
      throw SignalApiException(
        statusCode: response.statusCode,
        body: response.body,
      );
    }
  }
}

/// Exception thrown when a signal-cli-rest-api call returns an error status.
class SignalApiException implements Exception {
  const SignalApiException({required this.statusCode, required this.body});

  final int statusCode;
  final String body;

  @override
  String toString() => 'SignalApiException($statusCode): $body';
}
