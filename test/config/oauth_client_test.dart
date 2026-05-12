import 'dart:convert';

import 'package:dreamfinder/src/config/env.dart';
import 'package:dreamfinder/src/config/oauth_client.dart';
import 'package:dreamfinder/src/db/database.dart';
import 'package:dreamfinder/src/db/queries.dart';
import 'package:dreamfinder/src/logging/logger.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

void main() {
  late BotDatabase db;
  late Queries queries;
  late BotLogger log;

  setUp(() {
    db = BotDatabase.open(':memory:');
    queries = Queries(db);
    log = BotLogger(name: 'test', level: LogLevel.debug);
  });

  tearDown(() => db.close());

  /// Creates a mock HTTP client that returns the given response.
  http.Client _mockClient({
    required int statusCode,
    required Map<String, dynamic> body,
  }) =>
      http_testing.MockClient(
          (_) async => http.Response(jsonEncode(body), statusCode));

  /// Creates a mock client that returns a valid token response.
  http.Client _successClient({
    String accessToken = 'access-123',
    String refreshToken = 'refresh-456',
    int expiresIn = 28800,
  }) =>
      _mockClient(
        statusCode: 200,
        body: {
          'access_token': accessToken,
          'refresh_token': refreshToken,
          'expires_in': expiresIn,
        },
      );

  group('OAuthTokenManager', () {
    test('getAccessToken refreshes and returns access token', () async {
      final manager = OAuthTokenManager(
        queries: queries,
        log: log,
        initialRefreshToken: 'initial-refresh',
        httpClient: _successClient(),
      );

      final token = await manager.getAccessToken();
      expect(token, equals('access-123'));
    });

    test('caches token and reuses on subsequent calls', () async {
      var callCount = 0;
      final client = http_testing.MockClient((_) async {
        callCount++;
        return http.Response(
          jsonEncode({
            'access_token': 'access-$callCount',
            'refresh_token': 'refresh-$callCount',
            'expires_in': 28800,
          }),
          200,
        );
      });

      final manager = OAuthTokenManager(
        queries: queries,
        log: log,
        initialRefreshToken: 'initial',
        httpClient: client,
      );

      final first = await manager.getAccessToken();
      final second = await manager.getAccessToken();

      expect(first, equals('access-1'));
      expect(second, equals('access-1')); // Same — cached.
      expect(callCount, equals(1));
    });

    test('persists new refresh token to DB', () async {
      final manager = OAuthTokenManager(
        queries: queries,
        log: log,
        initialRefreshToken: 'initial-refresh',
        httpClient: _successClient(refreshToken: 'new-refresh'),
      );

      await manager.getAccessToken();

      final stored = queries.getOAuthToken('claude_refresh');
      expect(stored, equals('new-refresh'));
    });

    test('reads refresh token from DB when in-memory is null', () async {
      // Pre-populate DB with a refresh token.
      queries.saveOAuthToken('claude_refresh', 'db-refresh');

      final manager = OAuthTokenManager(
        queries: queries,
        log: log,
        // No initialRefreshToken — should fall back to DB.
        httpClient: _successClient(),
      );

      final token = await manager.getAccessToken();
      expect(token, equals('access-123'));
    });

    test('falls back to env refresh token when DB is empty', () async {
      final manager = OAuthTokenManager(
        queries: queries,
        log: log,
        initialRefreshToken: 'env-refresh',
        httpClient: _successClient(),
      );

      final token = await manager.getAccessToken();
      expect(token, equals('access-123'));
    });

    test('throws when no refresh token available', () async {
      final manager = OAuthTokenManager(
        queries: queries,
        log: log,
        // No token anywhere.
        httpClient: _successClient(),
      );

      expect(
        () => manager.getAccessToken(),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('No refresh token available'),
        )),
      );
    });

    test('throws on non-200 response', () async {
      final manager = OAuthTokenManager(
        queries: queries,
        log: log,
        initialRefreshToken: 'some-token',
        httpClient: _mockClient(
          statusCode: 400,
          body: {'error': 'invalid_grant'},
        ),
      );

      expect(
        () => manager.getAccessToken(),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('OAuth token refresh failed (400)'),
        )),
      );
    });

    test('invalidate forces re-fetch on next call', () async {
      var callCount = 0;
      final client = http_testing.MockClient((_) async {
        callCount++;
        return http.Response(
          jsonEncode({
            'access_token': 'access-$callCount',
            'refresh_token': 'refresh-$callCount',
            'expires_in': 28800,
          }),
          200,
        );
      });

      final manager = OAuthTokenManager(
        queries: queries,
        log: log,
        initialRefreshToken: 'initial',
        httpClient: client,
      );

      final first = await manager.getAccessToken();
      expect(first, equals('access-1'));

      manager.invalidate();

      final second = await manager.getAccessToken();
      expect(second, equals('access-2'));
      expect(callCount, equals(2));
    });

    group('health', () {
      test('returns unknown before first refresh', () {
        final manager = OAuthTokenManager(
          queries: queries,
          log: log,
          httpClient: _successClient(),
        );

        expect(manager.health.status, equals(TokenHealthStatus.unknown));
      });

      test('returns healthy after successful refresh', () async {
        final manager = OAuthTokenManager(
          queries: queries,
          log: log,
          initialRefreshToken: 'token',
          httpClient: _successClient(),
        );

        await manager.getAccessToken();

        expect(manager.health.status, equals(TokenHealthStatus.healthy));
        expect(manager.health.lastRefresh, isNotNull);
        expect(manager.health.expiresAt, isNotNull);
      });

      test('returns error after failed refresh', () async {
        final manager = OAuthTokenManager(
          queries: queries,
          log: log,
          initialRefreshToken: 'bad-token',
          httpClient: _mockClient(
            statusCode: 401,
            body: {'error': 'unauthorized'},
          ),
        );

        try {
          await manager.getAccessToken();
        } on StateError {
          // Expected.
        }

        expect(manager.health.status, equals(TokenHealthStatus.error));
        expect(manager.health.error, contains('OAuth token refresh failed'));
      });
    });

    test('sends correct form-encoded body', () async {
      String? capturedBody;
      String? capturedContentType;

      final client = http_testing.MockClient((request) async {
        capturedBody = request.body;
        capturedContentType = request.headers['content-type'];
        return http.Response(
          jsonEncode({
            'access_token': 'at',
            'refresh_token': 'rt',
            'expires_in': 3600,
          }),
          200,
        );
      });

      final manager = OAuthTokenManager(
        queries: queries,
        log: log,
        initialRefreshToken: 'my-refresh-token',
        httpClient: client,
      );

      await manager.getAccessToken();

      expect(capturedContentType, contains('x-www-form-urlencoded'));
      expect(capturedBody, contains('grant_type=refresh_token'));
      expect(capturedBody, contains('refresh_token=my-refresh-token'));
      expect(capturedBody, contains('client_id='));
    });
  });

  group('useOAuth in Env', () {
    test('returns false when no refresh token', () {
      final env = Env.forTesting();
      expect(env.useOAuth, isFalse);
    });

    test('returns false when refresh token is empty', () {
      final env = Env.forTesting(claudeRefreshToken: '');
      expect(env.useOAuth, isFalse);
    });

    test('returns true when refresh token is set', () {
      final env = Env.forTesting(claudeRefreshToken: 'some-token');
      expect(env.useOAuth, isTrue);
    });

    test('anthropicApiKey is nullable', () {
      final env = Env.forTesting(
        anthropicApiKey: null,
        claudeRefreshToken: 'token',
      );
      expect(env.anthropicApiKey, isNull);
      expect(env.useOAuth, isTrue);
    });
  });
}
