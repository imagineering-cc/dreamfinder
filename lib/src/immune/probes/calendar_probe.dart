/// Antibody for the calendar wrong-path incident (River read the empty
/// `/dreamfinder/` calendar instead of `/nick/imagineering-events/` for weeks,
/// silently reporting zero calendar awareness).
library;

import '../../agent/system_prompt.dart';
import '../probe.dart';

/// Signature of `CalendarRetriever.fetchUpcoming`, injected for testability.
typedef CalendarFetcher = Future<List<CalendarEvent>> Function({DateTime? now});

/// Asserts the calendar is not just reachable but is the *right* calendar.
///
/// Uses an identity assertion (a pinned recurring-event summary) rather than a
/// mere count — a wrong-tenant/obsolete calendar can be non-empty and still
/// wrong. Impedance-match nuance:
///
/// * pinned summary present → `ok`.
/// * non-empty but the pinned summary is absent → `failed` (reading *a*
///   calendar, but the wrong one — unambiguous).
/// * empty → `degraded`, not `failed`: an empty window is genuinely ambiguous
///   (quiet period vs wrong path), so it is surfaced on `/immune` for a human
///   but does not page.
class CalendarProbe extends Probe {
  CalendarProbe({
    required CalendarFetcher fetchUpcoming,
    required this.expectedSummarySubstring,
  }) : _fetch = fetchUpcoming;

  final CalendarFetcher _fetch;

  /// A substring of a known recurring event that the *correct* calendar always
  /// contains within the lookahead window (identity, not count).
  final String expectedSummarySubstring;

  @override
  String get id => 'probe_calendar';

  @override
  Future<ProbeResult> run() async {
    final events = await _fetch();
    if (events.isEmpty) {
      return ProbeResult(
        id: id,
        status: ProbeStatus.degraded,
        detail: 'calendar returned zero events — quiet period or wrong '
            'path/creds; check the CALENDAR_URL',
        coverage: const ['config-drift', 'wrong-tenant'],
      );
    }
    final match = events.any(
      (e) => e.summary.toLowerCase().contains(
            expectedSummarySubstring.toLowerCase(),
          ),
    );
    if (!match) {
      return ProbeResult(
        id: id,
        status: ProbeStatus.failed,
        detail: 'calendar has ${events.length} events but none match the '
            'expected recurring event "$expectedSummarySubstring" — wrong '
            'calendar/tenant',
        coverage: const ['config-drift', 'wrong-tenant'],
      );
    }
    return ProbeResult(
      id: id,
      status: ProbeStatus.ok,
      detail: 'calendar identity confirmed (${events.length} events, matched '
          '"$expectedSummarySubstring")',
      coverage: const ['config-drift', 'wrong-tenant'],
    );
  }
}
