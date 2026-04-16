import 'dart:convert';

import 'package:dreamfinder/src/livekit/livekit_server_client.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

class _MockHttpClient extends Mock implements http.Client {}

void main() {
  late _MockHttpClient mockHttp;
  late LiveKitServerClient client;

  const apiKey = 'test-api-key';
  const apiSecret = 'test-api-secret-that-is-long-enough-for-hs256';
  const serverUrl = 'https://lk.example.com';
  const room = 'tech-world';

  setUpAll(() {
    registerFallbackValue(Uri.parse('https://example.com'));
  });

  setUp(() {
    mockHttp = _MockHttpClient();
    client = LiveKitServerClient(
      serverUrl: serverUrl,
      apiKey: apiKey,
      apiSecret: apiSecret,
      httpClient: mockHttp,
    );
  });

  tearDown(() {
    client.close();
  });

  group('sendData', () {
    test('sends POST to correct Twirp endpoint', () async {
      when(
        () => mockHttp.post(
          any(),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
        ),
      ).thenAnswer((_) async => http.Response('{}', 200));

      await client.sendData(
        room: room,
        data: utf8.encode('hello'),
        topic: 'chat',
      );

      final captured = verify(
        () => mockHttp.post(
          captureAny(),
          headers: captureAny(named: 'headers'),
          body: captureAny(named: 'body'),
        ),
      ).captured;

      final uri = captured[0] as Uri;
      expect(uri.toString(),
          '$serverUrl/twirp/livekit.RoomService/SendData');
    });

    test('sends correct Content-Type and Authorization headers', () async {
      when(
        () => mockHttp.post(
          any(),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
        ),
      ).thenAnswer((_) async => http.Response('{}', 200));

      await client.sendData(
        room: room,
        data: utf8.encode('test'),
        topic: 'chat',
      );

      final captured = verify(
        () => mockHttp.post(
          any(),
          headers: captureAny(named: 'headers'),
          body: any(named: 'body'),
        ),
      ).captured;

      final headers = captured[0] as Map<String, String>;
      expect(headers['Content-Type'], 'application/json');
      expect(headers['Authorization'], startsWith('Bearer '));

      // JWT should have 3 dot-separated parts.
      final token = headers['Authorization']!.substring('Bearer '.length);
      final parts = token.split('.');
      expect(parts, hasLength(3));
    });

    test('encodes data as base64 in request body', () async {
      when(
        () => mockHttp.post(
          any(),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
        ),
      ).thenAnswer((_) async => http.Response('{}', 200));

      final payload = utf8.encode('{"text":"hello"}');

      await client.sendData(
        room: room,
        data: payload,
        topic: 'chat-response',
      );

      final captured = verify(
        () => mockHttp.post(
          any(),
          headers: any(named: 'headers'),
          body: captureAny(named: 'body'),
        ),
      ).captured;

      final body = jsonDecode(captured[0] as String) as Map<String, Object?>;
      expect(body['room'], room);
      expect(body['data'], base64Encode(payload));
      expect(body['kind'], 'RELIABLE');
      expect(body['topic'], 'chat-response');
    });

    test('includes destination_identities when provided', () async {
      when(
        () => mockHttp.post(
          any(),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
        ),
      ).thenAnswer((_) async => http.Response('{}', 200));

      await client.sendData(
        room: room,
        data: utf8.encode('hi'),
        topic: 'dm',
        destinationIdentities: ['user-123'],
      );

      final captured = verify(
        () => mockHttp.post(
          any(),
          headers: any(named: 'headers'),
          body: captureAny(named: 'body'),
        ),
      ).captured;

      final body = jsonDecode(captured[0] as String) as Map<String, Object?>;
      expect(body['destination_identities'], ['user-123']);
    });

    test('omits destination_identities when not provided', () async {
      when(
        () => mockHttp.post(
          any(),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
        ),
      ).thenAnswer((_) async => http.Response('{}', 200));

      await client.sendData(
        room: room,
        data: utf8.encode('hi'),
        topic: 'chat',
      );

      final captured = verify(
        () => mockHttp.post(
          any(),
          headers: any(named: 'headers'),
          body: captureAny(named: 'body'),
        ),
      ).captured;

      final body = jsonDecode(captured[0] as String) as Map<String, Object?>;
      expect(body.containsKey('destination_identities'), isFalse);
    });

    test('supports LOSSY kind', () async {
      when(
        () => mockHttp.post(
          any(),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
        ),
      ).thenAnswer((_) async => http.Response('{}', 200));

      await client.sendData(
        room: room,
        data: utf8.encode('pos'),
        topic: 'position',
        kind: DataKind.lossy,
      );

      final captured = verify(
        () => mockHttp.post(
          any(),
          headers: any(named: 'headers'),
          body: captureAny(named: 'body'),
        ),
      ).captured;

      final body = jsonDecode(captured[0] as String) as Map<String, Object?>;
      expect(body['kind'], 'LOSSY');
    });

    test('throws on non-200 response', () async {
      when(
        () => mockHttp.post(
          any(),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
        ),
      ).thenAnswer(
        (_) async => http.Response(
          '{"code":"not_found","msg":"room not found"}',
          404,
        ),
      );

      expect(
        () => client.sendData(
          room: room,
          data: utf8.encode('hi'),
          topic: 'chat',
        ),
        throwsA(isA<LiveKitApiException>()),
      );
    });
  });

  group('sendJson', () {
    test('encodes map as JSON bytes and sends', () async {
      when(
        () => mockHttp.post(
          any(),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
        ),
      ).thenAnswer((_) async => http.Response('{}', 200));

      await client.sendJson(
        room: room,
        topic: 'chat-response',
        payload: {'type': 'chat-response', 'text': 'hello'},
      );

      final captured = verify(
        () => mockHttp.post(
          any(),
          headers: any(named: 'headers'),
          body: captureAny(named: 'body'),
        ),
      ).captured;

      final body = jsonDecode(captured[0] as String) as Map<String, Object?>;
      // The data field should be base64-encoded JSON.
      final decodedData = utf8.decode(base64Decode(body['data']! as String));
      final innerJson =
          jsonDecode(decodedData) as Map<String, Object?>;

      expect(innerJson['type'], 'chat-response');
      expect(innerJson['text'], 'hello');
    });
  });

  group('JWT generation', () {
    test('produces valid JWT with correct claims', () async {
      when(
        () => mockHttp.post(
          any(),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
        ),
      ).thenAnswer((_) async => http.Response('{}', 200));

      await client.sendData(
        room: room,
        data: utf8.encode('test'),
        topic: 'chat',
      );

      final captured = verify(
        () => mockHttp.post(
          any(),
          headers: captureAny(named: 'headers'),
          body: any(named: 'body'),
        ),
      ).captured;

      final headers = captured[0] as Map<String, String>;
      final token = headers['Authorization']!.substring('Bearer '.length);

      // Decode JWT payload (second part, base64url-encoded).
      final payloadPart = token.split('.')[1];
      // Pad base64url to base64.
      final padded = base64Url.normalize(payloadPart);
      final payload =
          jsonDecode(utf8.decode(base64Url.decode(padded)))
              as Map<String, Object?>;

      expect(payload['iss'], apiKey);
      expect(payload['exp'], isA<int>());
      expect(payload['nbf'], isA<int>());

      final video = payload['video'] as Map<String, Object?>;
      expect(video['roomAdmin'], true);
    });
  });
}
