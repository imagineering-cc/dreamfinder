import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:dreamfinder/src/signal/models.dart';
import 'package:dreamfinder/src/signal/signal_client.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

class MockHttpClient extends Mock implements http.Client {}

void main() {
  late MockHttpClient mockClient;
  late SignalClient signalClient;

  const baseUrl = 'http://localhost:8080';
  const phoneNumber = '+1234567890';

  setUpAll(() {
    registerFallbackValue(Uri.parse('http://example.com'));
  });

  setUp(() {
    mockClient = MockHttpClient();
    signalClient = SignalClient(
      baseUrl: baseUrl,
      phoneNumber: phoneNumber,
      client: mockClient,
    );
  });

  group('SignalClient', () {
    test('about returns API version info', () async {
      when(() => mockClient.get(Uri.parse('$baseUrl/v1/about')))
          .thenAnswer((_) async => http.Response(
                jsonEncode({
                  'versions': ['v1', 'v2'],
                  'build': 42
                }),
                200,
              ));
      final about = await signalClient.about();
      expect(about.versions, isNotEmpty);
      expect(about.versions, contains('v1'));
    });

    test('listAccounts returns list of registered numbers', () async {
      when(() => mockClient.get(Uri.parse('$baseUrl/v1/accounts')))
          .thenAnswer((_) async => http.Response(
                jsonEncode(['+1234567890', '+0987654321']),
                200,
              ));
      final accounts = await signalClient.listAccounts();
      expect(accounts, isA<List<String>>());
      expect(accounts, hasLength(2));
    });

    test('sendMessage sends text and returns timestamp', () async {
      when(() => mockClient.post(Uri.parse('$baseUrl/v2/send'),
              headers: any(named: 'headers'), body: any(named: 'body')))
          .thenAnswer((_) async => http.Response(
                jsonEncode({'timestamp': '1709123456789'}),
                201,
              ));
      final result = await signalClient.sendMessage(
          recipient: '+0987654321', message: 'Hello!');
      expect(result.timestamp, isNotNull);
      expect(result.timestamp, isNotEmpty);
    });

    test('sendMessage to group uses group ID', () async {
      // Mock the listGroups endpoint that loadGroupMappings calls on cache miss.
      when(() => mockClient.get(
              Uri.parse('$baseUrl/v1/groups/$phoneNumber')))
          .thenAnswer((_) async => http.Response(
                jsonEncode([
                  {
                    'id': 'group.abc123==',
                    'internal_id': 'abc123==',
                    'name': 'Test Group',
                  },
                ]),
                200,
              ));
      when(() => mockClient.post(Uri.parse('$baseUrl/v2/send'),
              headers: any(named: 'headers'), body: any(named: 'body')))
          .thenAnswer((_) async => http.Response(
                jsonEncode({'timestamp': '1709123456789'}),
                201,
              ));
      final result = await signalClient.sendMessage(
          recipient: 'abc123==', message: 'Hello group!');
      expect(result.timestamp, isNotNull);
    });

    test('receiveMessages returns list of envelopes', () async {
      when(() => mockClient.get(Uri.parse('$baseUrl/v1/receive/$phoneNumber')))
          .thenAnswer((_) async => http.Response(
                jsonEncode([
                  {
                    'envelope': {
                      'source': '+0987654321',
                      'sourceUuid': 'uuid-123',
                      'timestamp': 1709123456789,
                      'dataMessage': {
                        'message': 'Hi there!',
                        'timestamp': 1709123456789,
                      },
                    },
                  },
                  {
                    'envelope': {
                      'source': '+1111111111',
                      'sourceUuid': 'uuid-456',
                      'timestamp': 1709123456790,
                      'dataMessage': {
                        'message': 'Another',
                        'timestamp': 1709123456790,
                        'groupInfo': {'groupId': 'group.abc123=='},
                      },
                    },
                  },
                ]),
                200,
              ));
      final envelopes = await signalClient.receiveMessages();
      expect(envelopes, isA<List<SignalEnvelope>>());
      expect(envelopes, hasLength(2));
      expect(envelopes[0].source, equals('+0987654321'));
      expect(envelopes[0].dataMessage?.message, equals('Hi there!'));
      expect(envelopes[1].dataMessage?.groupId, equals('group.abc123=='));
    });

    test('sendTypingIndicator sends PUT request', () async {
      when(() => mockClient.put(
              Uri.parse('$baseUrl/v1/typing-indicator/$phoneNumber'),
              headers: any(named: 'headers'),
              body: any(named: 'body')))
          .thenAnswer((_) async => http.Response('', 204));
      await signalClient.sendTypingIndicator(recipient: '+0987654321');
      verify(() => mockClient.put(
          Uri.parse('$baseUrl/v1/typing-indicator/$phoneNumber'),
          headers: any(named: 'headers'),
          body: any(named: 'body'))).called(1);
    });

    test('sendTypingIndicator to group uses group ID', () async {
      // Mock the listGroups endpoint that loadGroupMappings calls on cache miss.
      when(() => mockClient.get(
              Uri.parse('$baseUrl/v1/groups/$phoneNumber')))
          .thenAnswer((_) async => http.Response(
                jsonEncode([
                  {
                    'id': 'group.abc123==',
                    'internal_id': 'abc123==',
                    'name': 'Test Group',
                  },
                ]),
                200,
              ));
      when(() => mockClient.put(
              Uri.parse('$baseUrl/v1/typing-indicator/$phoneNumber'),
              headers: any(named: 'headers'),
              body: any(named: 'body')))
          .thenAnswer((_) async => http.Response('', 204));

      await signalClient.sendTypingIndicator(recipient: 'abc123==');

      final captured = verify(() => mockClient.put(
          Uri.parse('$baseUrl/v1/typing-indicator/$phoneNumber'),
          headers: any(named: 'headers'),
          body: captureAny(named: 'body'))).captured;
      final body = jsonDecode(captured.single as String) as Map<String, dynamic>;
      expect(body['recipient'], equals('group.abc123=='));
    });
  });
}
