import 'dart:convert';

import 'package:dreamfinder/src/agent/calendar_retriever.dart';
import 'package:dreamfinder/src/tools/cli_tools.dart';
import 'package:test/test.dart';

/// Builds a [VendoredCliRunner] that always returns a completed run with the
/// given [exitCode]/[stdout], capturing the args it was called with.
VendoredCliRunner _fakeRunner({
  int exitCode = 0,
  String stdout = '[]',
  String stderr = '',
  void Function(List<String> args, Map<String, String> env)? onCall,
}) {
  return ({required tool, required args, required env}) async {
    onCall?.call(args, env);
    return CliCompleted(exitCode: exitCode, stdout: stdout, stderr: stderr);
  };
}

CalendarRetriever _retriever(
  VendoredCliRunner runner, {
  String calendarUrl = 'nick/imagineering-events',
  int lookaheadDays = 7,
}) {
  return CalendarRetriever(
    calendarUrl: calendarUrl,
    radicaleBaseUrl: 'https://dav.example.com',
    radicaleUsername: 'nick',
    radicalePassword: 'secret',
    lookaheadDays: lookaheadDays,
    runner: runner,
  );
}

void main() {
  group('CalendarRetriever', () {
    test('returns parsed events from CLI JSON output', () async {
      final mockEvents = [
        {
          'uid': 'event-1',
          'summary': 'Bendigo Day Trip',
          'start': '2026-03-13T23:00:00.000Z',
          'end': '2026-03-14T04:30:00.000Z',
          'location': 'Southern Cross Station',
          'description': 'Board the V/Line...',
        },
        {
          'uid': 'event-2',
          'summary': "Round 3: We're getting there!",
          'start': '2026-03-28T08:00:00.000Z',
          'end': '2026-03-28T10:00:00.000Z',
          'location': 'The Abode, 318 Russell St',
          'description': 'Build sprint meetup.',
        },
      ];

      final retriever = _retriever(_fakeRunner(stdout: jsonEncode(mockEvents)));
      final events = await retriever.fetchUpcoming();

      expect(events, hasLength(2));
      expect(events[0].summary, 'Bendigo Day Trip');
      expect(events[0].location, 'Southern Cross Station');
      expect(events[1].summary, "Round 3: We're getting there!");
    });

    test('returns empty list when CLI returns empty array', () async {
      final retriever = _retriever(_fakeRunner(stdout: '[]'));
      expect(await retriever.fetchUpcoming(), isEmpty);
    });

    test('returns empty list on garbage / unparseable output', () async {
      final retriever = _retriever(_fakeRunner(stdout: 'not json at all'));
      expect(await retriever.fetchUpcoming(), isEmpty);
    });

    test('returns empty list on empty stdout', () async {
      final retriever = _retriever(_fakeRunner(stdout: ''));
      expect(await retriever.fetchUpcoming(), isEmpty);
    });

    test('returns empty list on non-zero exit code', () async {
      final retriever = _retriever(
        _fakeRunner(exitCode: 1, stdout: '', stderr: 'auth failed'),
      );
      expect(await retriever.fetchUpcoming(), isEmpty);
    });

    test('returns empty list on CLI launch failure', () async {
      final retriever = _retriever(
        ({required tool, required args, required env}) async =>
            const CliLaunchFailure('node not found'),
      );
      expect(await retriever.fetchUpcoming(), isEmpty);
    });

    test('returns empty list on CLI timeout', () async {
      final retriever = _retriever(
        ({required tool, required args, required env}) async =>
            const CliTimeout(),
      );
      expect(await retriever.fetchUpcoming(), isEmpty);
    });

    test('returns empty list when runner throws', () async {
      final retriever = _retriever(
        ({required tool, required args, required env}) async =>
            throw Exception('boom'),
      );
      expect(await retriever.fetchUpcoming(), isEmpty);
    });

    test('passes calendar + from/to date range to the CLI', () async {
      late List<String> capturedArgs;
      final retriever = _retriever(
        _fakeRunner(onCall: (args, _) => capturedArgs = args),
      );

      final now = DateTime.utc(2026, 3, 13, 10, 0);
      await retriever.fetchUpcoming(now: now);

      expect(capturedArgs.first, 'list-events');
      expect(
          capturedArgs, containsAll(<String>['--calendar', '--from', '--to']));
      // --calendar value follows the flag.
      final calIdx = capturedArgs.indexOf('--calendar');
      expect(capturedArgs[calIdx + 1], 'nick/imagineering-events');
      final fromIdx = capturedArgs.indexOf('--from');
      expect(capturedArgs[fromIdx + 1], contains('2026-03-13'));
      // Default lookahead is 7 days.
      final toIdx = capturedArgs.indexOf('--to');
      expect(capturedArgs[toIdx + 1], contains('2026-03-20'));
    });

    test('injects radicale credentials into the CLI environment', () async {
      late Map<String, String> capturedEnv;
      final retriever = _retriever(
        _fakeRunner(onCall: (_, env) => capturedEnv = env),
      );

      await retriever.fetchUpcoming();

      expect(capturedEnv['RADICALE_BASE_URL'], 'https://dav.example.com');
      expect(capturedEnv['RADICALE_USERNAME'], 'nick');
      expect(capturedEnv['RADICALE_PASSWORD'], 'secret');
      expect(capturedEnv.containsKey('PATH'), isTrue);
    });

    test('respects custom lookahead days', () async {
      late List<String> capturedArgs;
      final retriever = _retriever(
        _fakeRunner(onCall: (args, _) => capturedArgs = args),
        lookaheadDays: 14,
      );

      final now = DateTime.utc(2026, 3, 13, 10, 0);
      await retriever.fetchUpcoming(now: now);

      final toIdx = capturedArgs.indexOf('--to');
      expect(capturedArgs[toIdx + 1], contains('2026-03-27'));
    });

    test('events are sorted by start time', () async {
      final mockEvents = [
        {
          'uid': 'event-2',
          'summary': 'Later Event',
          'start': '2026-03-28T08:00:00.000Z',
          'end': '2026-03-28T10:00:00.000Z',
        },
        {
          'uid': 'event-1',
          'summary': 'Earlier Event',
          'start': '2026-03-14T10:00:00.000Z',
          'end': '2026-03-14T12:00:00.000Z',
        },
      ];

      final retriever = _retriever(_fakeRunner(stdout: jsonEncode(mockEvents)));
      final events = await retriever.fetchUpcoming();

      expect(events[0].summary, 'Earlier Event');
      expect(events[1].summary, 'Later Event');
    });
  });
}
