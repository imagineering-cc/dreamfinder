import 'dart:convert';

import 'package:dreamfinder/src/logging/logger.dart';
import 'package:test/test.dart';

void main() {
  group('LogLevel.fromString', () {
    test('parses known levels case-insensitively', () {
      expect(LogLevel.fromString('debug'), LogLevel.debug);
      expect(LogLevel.fromString('INFO'), LogLevel.info);
      expect(LogLevel.fromString('Warning'), LogLevel.warning);
      expect(LogLevel.fromString('ERROR'), LogLevel.error);
    });

    test('defaults to info for unknown strings', () {
      expect(LogLevel.fromString('verbose'), LogLevel.info);
      expect(LogLevel.fromString(''), LogLevel.info);
    });
  });

  group('BotLogger', () {
    test('outputs JSON with required fields', () {
      final output = <String>[];
      final logger = BotLogger(
        name: 'Test',
        level: LogLevel.debug,
        sink: output.add,
      );

      logger.info('hello world');

      expect(output, hasLength(1));
      final json = jsonDecode(output.first) as Map<String, dynamic>;
      expect(json['level'], 'info');
      expect(json['logger'], 'Test');
      expect(json['message'], 'hello world');
      expect(json, contains('timestamp'));
    });

    test('filters messages below configured level', () {
      final output = <String>[];
      final logger = BotLogger(
        name: 'Test',
        level: LogLevel.warning,
        sink: output.add,
      );

      logger.debug('should be hidden');
      logger.info('should be hidden');
      logger.warning('should appear');
      logger.error('should appear');

      expect(output, hasLength(2));
      expect(output[0], contains('"warning"'));
      expect(output[1], contains('"error"'));
    });

    test('includes extra fields when provided', () {
      final output = <String>[];
      final logger = BotLogger(
        name: 'Test',
        level: LogLevel.debug,
        sink: output.add,
      );

      logger.info('request handled', extra: {'chatId': 'g1', 'latency_ms': 42});

      final json = jsonDecode(output.first) as Map<String, dynamic>;
      final data = json['data'] as Map<String, dynamic>;
      expect(data['chatId'], 'g1');
      expect(data['latency_ms'], 42);
      // Verify extras are namespaced — no collision with reserved keys.
      expect(json, isNot(contains('chatId')));
    });

    test('child logger inherits level and sink', () {
      final output = <String>[];
      final parent = BotLogger(
        name: 'Main',
        level: LogLevel.warning,
        sink: output.add,
      );

      final child = parent.child('Scheduler');
      child.info('hidden');
      child.error('visible');

      expect(output, hasLength(1));
      final json = jsonDecode(output.first) as Map<String, dynamic>;
      expect(json['logger'], 'Scheduler');
    });

    test('defaults to stderr sink when none provided', () {
      // Just verify construction doesn't throw — we can't easily capture
      // stderr in a unit test.
      final logger = BotLogger(name: 'Test', level: LogLevel.info);
      expect(logger, isNotNull);
    });
  });
}
