import 'package:dreamfinder/src/session/session.dart';
import 'package:test/test.dart';

void main() {
  group('isSessionMessage', () {
    test('matches "let\'s have a session"', () {
      expect(isSessionMessage("let's have a session"), isTrue);
      expect(isSessionMessage("Let's have a session"), isTrue);
    });

    test('matches "session time"', () {
      expect(isSessionMessage('session time'), isTrue);
      expect(isSessionMessage('Session time'), isTrue);
      expect(isSessionMessage('SESSION TIME'), isTrue);
    });

    test('matches "start a session"', () {
      expect(isSessionMessage('start a session'), isTrue);
      expect(isSessionMessage('Start a session'), isTrue);
    });

    test('matches "imagineering session"', () {
      expect(isSessionMessage('imagineering session'), isTrue);
      expect(isSessionMessage('Imagineering Session'), isTrue);
    });

    test('matches "co-working session"', () {
      expect(isSessionMessage('co-working session'), isTrue);
      expect(isSessionMessage('Co-working session'), isTrue);
    });

    test('matches "let\'s work together"', () {
      expect(isSessionMessage("let's work together"), isTrue);
      expect(isSessionMessage("Let's work together"), isTrue);
    });

    test('matches "lets work together" (without apostrophe)', () {
      expect(isSessionMessage('lets work together'), isTrue);
    });

    test('is case insensitive', () {
      expect(isSessionMessage('SESSION TIME'), isTrue);
      expect(isSessionMessage('START A SESSION'), isTrue);
      expect(isSessionMessage("LET'S WORK TOGETHER"), isTrue);
    });

    test('does not match past-tense references', () {
      expect(isSessionMessage('the session was great'), isFalse);
    });

    test('does not match future non-trigger references', () {
      expect(isSessionMessage("I'll send it in the next session"), isFalse);
    });

    test('does not match random text', () {
      expect(isSessionMessage('hello there'), isFalse);
      expect(isSessionMessage('create a task'), isFalse);
      expect(isSessionMessage('good morning'), isFalse);
      expect(isSessionMessage('what are we working on?'), isFalse);
    });
  });
}
