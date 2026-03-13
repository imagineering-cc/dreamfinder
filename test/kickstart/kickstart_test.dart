import 'package:dreamfinder/src/kickstart/kickstart.dart';
import 'package:test/test.dart';

void main() {
  group('isKickstartMessage', () {
    test('matches "kickstart"', () {
      expect(isKickstartMessage('kickstart'), isTrue);
      expect(isKickstartMessage('Kickstart'), isTrue);
      expect(isKickstartMessage('KICKSTART'), isTrue);
    });

    test('matches "let\'s set up"', () {
      expect(isKickstartMessage("let's set up"), isTrue);
      expect(isKickstartMessage("Let's set up"), isTrue);
      expect(isKickstartMessage("Let's Set Up"), isTrue);
    });

    test('matches "lets set up" (without apostrophe)', () {
      expect(isKickstartMessage('lets set up'), isTrue);
      expect(isKickstartMessage('Lets set up'), isTrue);
    });

    test('matches "set up dreamfinder"', () {
      expect(isKickstartMessage('set up dreamfinder'), isTrue);
      expect(isKickstartMessage('Set up Dreamfinder'), isTrue);
    });

    test('matches "set up" with any bot name', () {
      expect(isKickstartMessage('set up mybot'), isTrue);
    });

    test('matches "get started"', () {
      expect(isKickstartMessage('get started'), isTrue);
      expect(isKickstartMessage('Get Started'), isTrue);
      expect(isKickstartMessage('GET STARTED'), isTrue);
    });

    test('matches "onboard" and "onboarding"', () {
      expect(isKickstartMessage('onboard'), isTrue);
      expect(isKickstartMessage('onboarding'), isTrue);
      expect(isKickstartMessage('Onboarding'), isTrue);
    });

    test('matches within a sentence', () {
      expect(
        isKickstartMessage("Hey Dreamfinder, let's set up the workspace"),
        isTrue,
      );
      expect(
        isKickstartMessage('Can you help us get started?'),
        isTrue,
      );
      expect(
        isKickstartMessage('Time to kickstart this project!'),
        isTrue,
      );
    });

    test('does not match unrelated text', () {
      expect(isKickstartMessage('hello there'), isFalse);
      expect(isKickstartMessage('create a task'), isFalse);
      expect(isKickstartMessage('good morning'), isFalse);
      expect(isKickstartMessage('set the timer'), isFalse);
    });

    test('does not match partial words', () {
      // "kickstarter" should match because "kickstart" is at a word boundary
      // before "er" — but \b between 't' and 'e' is not a boundary since both
      // are word chars. Let's verify.
      expect(isKickstartMessage('kickstarter'), isFalse);
    });
  });
}
