import 'dart:convert';

import 'package:dreamfinder/src/agent/calendar_retriever.dart';
import 'package:dreamfinder/src/mcp/mcp_manager.dart';
import 'package:test/test.dart';

void main() {
  group('CalendarRetriever', () {
    late McpManager mcpManager;
    late CalendarRetriever retriever;

    const calendarUrl = 'https://dav.example.com/user/events/';

    setUp(() {
      mcpManager = McpManager();
    });

    test('returns parsed events from MCP response', () async {
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

      mcpManager.addServerForTesting(
        'radicale',
        McpToolInfo(
          name: 'radicale_list_events',
          description: 'List events',
          handler: (args) async => jsonEncode(mockEvents),
        ),
      );

      retriever = CalendarRetriever(
        mcpManager: mcpManager,
        calendarUrl: calendarUrl,
      );

      final events = await retriever.fetchUpcoming();

      expect(events, hasLength(2));
      expect(events[0].summary, 'Bendigo Day Trip');
      expect(events[0].location, 'Southern Cross Station');
      expect(events[1].summary, "Round 3: We're getting there!");
    });

    test('returns empty list when MCP returns empty array', () async {
      mcpManager.addServerForTesting(
        'radicale',
        McpToolInfo(
          name: 'radicale_list_events',
          description: 'List events',
          handler: (args) async => '[]',
        ),
      );

      retriever = CalendarRetriever(
        mcpManager: mcpManager,
        calendarUrl: calendarUrl,
      );

      final events = await retriever.fetchUpcoming();
      expect(events, isEmpty);
    });

    test('returns empty list when MCP call fails', () async {
      mcpManager.addServerForTesting(
        'radicale',
        McpToolInfo(
          name: 'radicale_list_events',
          description: 'List events',
          handler: (args) async => throw Exception('MCP server down'),
        ),
      );

      retriever = CalendarRetriever(
        mcpManager: mcpManager,
        calendarUrl: calendarUrl,
      );

      final events = await retriever.fetchUpcoming();
      expect(events, isEmpty);
    });

    test('passes correct date range to MCP tool', () async {
      Map<String, dynamic>? capturedArgs;

      mcpManager.addServerForTesting(
        'radicale',
        McpToolInfo(
          name: 'radicale_list_events',
          description: 'List events',
          handler: (args) async {
            capturedArgs = args;
            return '[]';
          },
        ),
      );

      retriever = CalendarRetriever(
        mcpManager: mcpManager,
        calendarUrl: calendarUrl,
      );

      final now = DateTime.utc(2026, 3, 13, 10, 0);
      await retriever.fetchUpcoming(now: now);

      expect(capturedArgs, isNotNull);
      expect(capturedArgs!['calendar_url'], calendarUrl);
      expect(capturedArgs!['start'], contains('2026-03-13'));
      // Default lookahead is 7 days.
      expect(capturedArgs!['end'], contains('2026-03-20'));
    });

    test('respects custom lookahead days', () async {
      Map<String, dynamic>? capturedArgs;

      mcpManager.addServerForTesting(
        'radicale',
        McpToolInfo(
          name: 'radicale_list_events',
          description: 'List events',
          handler: (args) async {
            capturedArgs = args;
            return '[]';
          },
        ),
      );

      retriever = CalendarRetriever(
        mcpManager: mcpManager,
        calendarUrl: calendarUrl,
        lookaheadDays: 14,
      );

      final now = DateTime.utc(2026, 3, 13, 10, 0);
      await retriever.fetchUpcoming(now: now);

      expect(capturedArgs!['end'], contains('2026-03-27'));
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

      mcpManager.addServerForTesting(
        'radicale',
        McpToolInfo(
          name: 'radicale_list_events',
          description: 'List events',
          handler: (args) async => jsonEncode(mockEvents),
        ),
      );

      retriever = CalendarRetriever(
        mcpManager: mcpManager,
        calendarUrl: calendarUrl,
      );

      final events = await retriever.fetchUpcoming();

      expect(events[0].summary, 'Earlier Event');
      expect(events[1].summary, 'Later Event');
    });
  });
}
