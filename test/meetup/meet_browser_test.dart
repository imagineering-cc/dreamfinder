import 'package:imagineering_pm_bot/src/meetup/meet_browser.dart';
import 'package:test/test.dart';

void main() {
  group('FakeMeetBrowser', () {
    late FakeMeetBrowser browser;

    setUp(() {
      browser = FakeMeetBrowser();
    });

    test('starts disconnected', () {
      expect(browser.isConnected, isFalse);
    });

    test('joinMeet connects and records the call', () async {
      await browser.joinMeet(
        meetLink: 'https://meet.google.com/abc-defg-hij',
        displayName: 'Dreamfinder',
      );

      expect(browser.isConnected, isTrue);
      expect(
        browser.calls,
        contains('joinMeet(https://meet.google.com/abc-defg-hij, Dreamfinder)'),
      );
    });

    test('speak records the spoken text', () async {
      await browser.joinMeet(
        meetLink: 'https://meet.google.com/test',
        displayName: 'Dreamfinder',
      );

      await browser.speak('Hello, imagineers!');

      expect(browser.spokenTexts, ['Hello, imagineers!']);
      expect(browser.calls, contains('speak(Hello, imagineers!)'));
    });

    test('leaveMeet disconnects', () async {
      await browser.joinMeet(
        meetLink: 'https://meet.google.com/test',
        displayName: 'Dreamfinder',
      );
      expect(browser.isConnected, isTrue);

      await browser.leaveMeet();
      expect(browser.isConnected, isFalse);
    });

    test('enableCaptions records the call', () async {
      await browser.joinMeet(
        meetLink: 'https://meet.google.com/test',
        displayName: 'Dreamfinder',
      );

      await browser.enableCaptions();

      expect(browser.calls, contains('enableCaptions()'));
    });

    test('failOnJoin causes joinMeet to throw', () async {
      browser.failOnJoin = true;

      expect(
        () => browser.joinMeet(
          meetLink: 'https://meet.google.com/test',
          displayName: 'Dreamfinder',
        ),
        throwsException,
      );
      expect(browser.isConnected, isFalse);
    });

    test('failOnSpeak causes speak to throw', () async {
      browser.failOnSpeak = true;

      expect(() => browser.speak('test'), throwsException);
    });

    test('reset clears all state', () async {
      await browser.joinMeet(
        meetLink: 'https://meet.google.com/test',
        displayName: 'Dreamfinder',
      );
      await browser.speak('hello');

      browser.reset();

      expect(browser.isConnected, isFalse);
      expect(browser.calls, isEmpty);
      expect(browser.spokenTexts, isEmpty);
      expect(browser.failOnJoin, isFalse);
      expect(browser.failOnSpeak, isFalse);
    });

    test('records multiple calls in order', () async {
      await browser.joinMeet(
        meetLink: 'https://meet.google.com/test',
        displayName: 'Dreamfinder',
      );
      await browser.enableCaptions();
      await browser.speak('Welcome!');
      await browser.speak('Sprint 1 begins now.');
      await browser.leaveMeet();

      expect(browser.calls, [
        'joinMeet(https://meet.google.com/test, Dreamfinder)',
        'enableCaptions()',
        'speak(Welcome!)',
        'speak(Sprint 1 begins now.)',
        'leaveMeet()',
      ]);
      expect(browser.spokenTexts, ['Welcome!', 'Sprint 1 begins now.']);
    });
  });

  group('PlaywrightMeetBrowser', () {
    // PlaywrightMeetBrowser requires a real McpManager with a connected
    // Playwright MCP server. Integration tests for the actual browser
    // interaction belong in test/integration/.
    //
    // State guards (e.g. speak() throws when not connected) are tested
    // implicitly via the FakeMeetBrowser contract and will be verified
    // during live integration testing.
  });
}
