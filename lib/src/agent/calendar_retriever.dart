import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import '../tools/cli_tools.dart';
import 'system_prompt.dart';

/// Runs a vendored CLI and returns its [CliOutcome]. Signature mirrors
/// [execVendoredCli]; injected so tests can drive [CalendarRetriever] without a
/// live Radicale server.
typedef VendoredCliRunner = Future<CliOutcome> Function({
  required String tool,
  required List<String> args,
  required Map<String, String> env,
});

/// Fetches upcoming calendar events from Radicale via the vendored `radicale`
/// CLI (`cli-tools/radicale.mjs`).
///
/// The CLI expands recurrence + timezones server-side (RFC 4791 expand) and
/// emits JSON `[{uid,summary,description,start,end,location}]` in UTC — exactly
/// the shape [CalendarEvent.fromJson] parses. Used to inject event awareness
/// into the system prompt so Dreamfinder can naturally reference upcoming
/// meetings, trips, and deadlines.
class CalendarRetriever {
  CalendarRetriever({
    required this.calendarUrl,
    required this.radicaleBaseUrl,
    required this.radicaleUsername,
    required this.radicalePassword,
    this.lookaheadDays = 7,
    VendoredCliRunner? runner,
  }) : _runner = runner ?? execVendoredCli;

  /// Full URL (or `<user>/<calendar>` path) of the Radicale calendar to query.
  final String calendarUrl;

  /// Radicale credentials, injected into the CLI subprocess environment.
  final String radicaleBaseUrl;
  final String radicaleUsername;
  final String radicalePassword;

  /// How many days ahead to look for events.
  final int lookaheadDays;

  /// Vendored-CLI runner (real [execVendoredCli] by default; overridable in
  /// tests to avoid spawning `node` / hitting a live server).
  final VendoredCliRunner _runner;

  /// Fetches upcoming events from Radicale.
  ///
  /// Returns an empty list on any failure (launch failure, timeout, non-zero
  /// exit, or unparseable output) — calendar awareness is a non-critical
  /// feature and must never break the bot. Accepts an optional [now] for
  /// testing.
  Future<List<CalendarEvent>> fetchUpcoming({DateTime? now}) async {
    final start = now ?? DateTime.now().toUtc();
    final end = start.add(Duration(days: lookaheadDays));

    try {
      final outcome = await _runner(
        tool: 'radicale',
        args: <String>[
          'list-events',
          '--calendar',
          calendarUrl,
          '--from',
          start.toIso8601String(),
          '--to',
          end.toIso8601String(),
        ],
        env: <String, String>{
          'PATH':
              Platform.environment['PATH'] ?? '/usr/local/bin:/usr/bin:/bin',
          'RADICALE_BASE_URL': radicaleBaseUrl,
          'RADICALE_USERNAME': radicaleUsername,
          'RADICALE_PASSWORD': radicalePassword,
        },
      );

      if (outcome is! CliCompleted || outcome.exitCode != 0) {
        developer.log(
          'Calendar CLI did not complete successfully: $outcome',
          name: 'CalendarRetriever',
        );
        return [];
      }

      final decoded = jsonDecode(outcome.stdout);
      if (decoded is! List) return [];

      final events = <CalendarEvent>[
        for (final item in decoded)
          if (item is Map<String, dynamic>) CalendarEvent.fromJson(item),
      ];

      // Sort by start time (chronological).
      events.sort((a, b) => a.start.compareTo(b.start));

      return events;
    } on Object catch (e) {
      // Catch Object (not just Exception): jsonDecode throws FormatException
      // and CalendarEvent.fromJson can throw a TypeError on a missing `start`
      // — both must degrade to "no events", never crash the bot.
      developer.log(
        'Failed to fetch calendar events: $e',
        name: 'CalendarRetriever',
      );
      return [];
    }
  }
}
