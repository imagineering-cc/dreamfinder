import 'dart:convert';
import 'dart:developer' as developer;

import '../mcp/mcp_manager.dart';
import 'system_prompt.dart';

/// Fetches upcoming calendar events from the Radicale MCP server.
///
/// Used to inject event awareness into the system prompt so Dreamfinder
/// can naturally reference upcoming meetings, trips, and deadlines.
class CalendarRetriever {
  CalendarRetriever({
    required this.mcpManager,
    required this.calendarUrl,
    this.lookaheadDays = 7,
  });

  final McpManager mcpManager;

  /// Full URL of the Radicale calendar to query.
  final String calendarUrl;

  /// How many days ahead to look for events.
  final int lookaheadDays;

  /// Fetches upcoming events from Radicale.
  ///
  /// Returns an empty list if the MCP call fails (non-critical feature).
  /// Accepts an optional [now] for testing.
  Future<List<CalendarEvent>> fetchUpcoming({DateTime? now}) async {
    final start = now ?? DateTime.now().toUtc();
    final end = start.add(Duration(days: lookaheadDays));

    try {
      final result = await mcpManager.callTool(
        'radicale_list_events',
        <String, dynamic>{
          'calendar_url': calendarUrl,
          'start': start.toIso8601String(),
          'end': end.toIso8601String(),
        },
      );

      final decoded = jsonDecode(result);
      if (decoded is! List) return [];

      final events = <CalendarEvent>[
        for (final item in decoded)
          if (item is Map<String, dynamic>) CalendarEvent.fromJson(item),
      ];

      // Sort by start time (chronological).
      events.sort((a, b) => a.start.compareTo(b.start));

      return events;
    } on Exception catch (e) {
      developer.log(
        'Failed to fetch calendar events: $e',
        name: 'CalendarRetriever',
      );
      return [];
    }
  }
}
