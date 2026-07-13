import 'package:dreamfinder/src/agent/agent_loop.dart';
import 'package:dreamfinder/src/agent/system_prompt.dart';
import 'package:test/test.dart';
import 'package:timezone/data/latest.dart' as tzdata;

/// The system prompt must always anchor River in the current date & time.
/// Without this anchor River confabulates the date (observed live 2026-07-13:
/// it claimed "Saturday July 12th" on Monday the 13th) — a real hole for a
/// deadline-driven PM bot. The anchor is unconditional: it does NOT depend on
/// there being any calendar events.
void main() {
  setUpAll(tzdata.initializeTimeZones);

  group('buildSystemPrompt time anchor', () {
    // 2026-07-13 10:17 UTC == 2026-07-13 20:17 Melbourne (AEST, UTC+10, winter).
    final fixedNow = DateTime.utc(2026, 7, 13, 10, 17);

    const input = AgentInput(
      text: 'hi',
      chatId: 'group-1',
      senderId: 'user-1',
      senderName: 'Alice',
      isAdmin: false,
    );

    test('renders weekday, date, and local time in the community timezone', () {
      final prompt = buildSystemPrompt(
        input,
        now: fixedNow,
        eventTimeZone: 'Australia/Melbourne',
      );

      // Anchored to Melbourne local time, not UTC.
      expect(
        prompt,
        contains('Current date & time: Monday, 13 July 2026, 20:17 AEST'),
      );
      // It lives in the Current Context section.
      expect(prompt, contains('## Current Context'));
    });

    test('falls back to UTC when no timezone is configured', () {
      final prompt = buildSystemPrompt(input, now: fixedNow);

      expect(
        prompt,
        contains('Current date & time: Monday, 13 July 2026, 10:17 UTC'),
      );
    });

    test('falls back to UTC when the timezone is invalid', () {
      final prompt = buildSystemPrompt(
        input,
        now: fixedNow,
        eventTimeZone: 'Invalid/Timezone',
      );

      expect(prompt, contains('Monday, 13 July 2026, 10:17 UTC'));
    });

    test('anchor is present even for system-initiated prompts (no events)', () {
      const systemInput = AgentInput(
        text: 'run nudge',
        chatId: 'group-1',
        senderId: 'system',
        isAdmin: true,
        isSystemInitiated: true,
      );

      final prompt = buildSystemPrompt(
        systemInput,
        now: fixedNow,
        eventTimeZone: 'Australia/Melbourne',
      );

      // Grounding must not depend on a human sender or any calendar events.
      expect(prompt, contains('Current date & time: Monday, 13 July 2026'));
    });
  });
}
