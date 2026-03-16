import 'dart:convert';

import 'package:dreamfinder/src/matrix/matrix_auth.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

void main() {
  const homeserver = 'https://matrix.test';

  group('MatrixAuth', () {
    test('returns pre-configured access token directly', () async {
      final auth = MatrixAuth(
        homeserver: homeserver,
        accessToken: 'pre-set-token',
      );

      final token = await auth.getAccessToken();
      expect(token, 'pre-set-token');
    });

    test('logs in with username/password', () async {
      http.Request? capturedRequest;

      final mockClient = http_testing.MockClient((request) async {
        capturedRequest = request;
        return http.Response(
          jsonEncode({'access_token': 'login-token'}),
          200,
        );
      });

      final auth = MatrixAuth(
        homeserver: homeserver,
        username: 'bot',
        password: 'secret',
        client: mockClient,
      );

      final token = await auth.getAccessToken();
      expect(token, 'login-token');

      // Verify login request body.
      final body =
          jsonDecode(capturedRequest!.body) as Map<String, dynamic>;
      expect(body['type'], 'm.login.password');
      expect(
        (body['identifier'] as Map<String, dynamic>)['user'],
        'bot',
      );
      expect(body['password'], 'secret');
    });

    test('caches token after login', () async {
      var callCount = 0;

      final mockClient = http_testing.MockClient((request) async {
        callCount++;
        return http.Response(
          jsonEncode({'access_token': 'cached-token'}),
          200,
        );
      });

      final auth = MatrixAuth(
        homeserver: homeserver,
        username: 'bot',
        password: 'pass',
        client: mockClient,
      );

      await auth.getAccessToken();
      await auth.getAccessToken();

      // Should only call the server once.
      expect(callCount, 1);
    });

    test('throws StateError when no auth configured', () async {
      final auth = MatrixAuth(homeserver: homeserver);

      expect(
        () => auth.getAccessToken(),
        throwsA(isA<StateError>()),
      );
    });

    test('throws MatrixAuthException on login failure', () async {
      final mockClient = http_testing.MockClient((request) async {
        return http.Response(
          jsonEncode({'errcode': 'M_FORBIDDEN'}),
          403,
        );
      });

      final auth = MatrixAuth(
        homeserver: homeserver,
        username: 'bot',
        password: 'wrong',
        client: mockClient,
      );

      expect(
        () => auth.getAccessToken(),
        throwsA(isA<MatrixAuthException>()),
      );
    });
  });
}
