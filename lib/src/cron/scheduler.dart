/// Timer-based scheduler for recurring tasks.
///
/// Currently handles:
/// - **Standup prompts**: Sends a prompt message at the configured hour.
/// - **Data cleanup**: Removes old reminders and calendar reminder records.
///
/// The scheduler checks all standup configs every minute and fires actions
/// when the current time matches a configured hour. Idempotent — duplicate
/// sends are prevented by checking for existing standup sessions.
library;

import 'dart:async';

import '../db/queries.dart';
import '../db/schema.dart';

export '../db/schema.dart' show CalendarReminderWindow;

/// Callback for sending a message to a Signal group.
typedef SendMessageFn = Future<void> Function(String groupId, String message);

/// Periodic scheduler for standup prompts and data cleanup.
class Scheduler {
  Scheduler({
    required this.queries,
    required this.sendMessage,
  });

  final Queries queries;
  final SendMessageFn sendMessage;
  Timer? _timer;

  /// Tracks the last date (YYYY-MM-DD) that data cleanup ran, to ensure
  /// it fires exactly once per day regardless of timer drift.
  String? _lastCleanupDate;

  /// Starts the scheduler, ticking every 60 seconds.
  void start() {
    _timer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => tick(DateTime.now()),
    );
  }

  /// Stops the scheduler.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Runs one scheduler cycle for the given [now] time.
  ///
  /// Public so tests can call it directly with a controlled timestamp.
  Future<void> tick(DateTime now) async {
    final configs = queries.getAllStandupConfigs();
    for (final config in configs) {
      if (!config.enabled) continue;

      // Skip weekends if configured.
      if (config.skipWeekends && _isWeekend(now)) continue;

      final today = _dateString(now);

      // Check if it's prompt hour and no session exists yet today.
      // TODO(timezone): Convert `now` to `config.timezone` before comparing.
      // Currently uses server-local time; the timezone field is stored but
      // not yet applied. Add the `timezone` package when needed.
      if (now.hour == config.promptHour) {
        final existingSession =
            queries.getActiveStandupSession(config.signalGroupId, today);
        if (existingSession == null) {
          await _sendStandupPrompt(config, today);
        }
      }
    }

    // Run data cleanup once per day after 3 AM. Uses a date guard instead
    // of exact minute matching so timer drift or restarts can't skip a day.
    final todayStr = _dateString(now);
    if (now.hour >= 3 && _lastCleanupDate != todayStr) {
      _lastCleanupDate = todayStr;
      cleanOldData();
    }
  }

  /// Sends the standup prompt message and creates the session record.
  Future<void> _sendStandupPrompt(
    StandupConfigRecord config,
    String date,
  ) async {
    final message = "Good morning! Time for today's standup.\n\n"
        'Please share:\n'
        '1. What did you work on yesterday?\n'
        '2. What are you working on today?\n'
        '3. Any blockers?\n\n'
        'Just reply naturally — I\'ll record your update.';

    await sendMessage(config.signalGroupId, message);

    queries.createStandupSession(
      signalGroupId: config.signalGroupId,
      date: date,
    );
  }

  /// Removes old reminders and calendar reminders from the database.
  void cleanOldData() {
    queries.cleanOldReminders(olderThanDays: 7);
    queries.cleanOldCalendarReminders(olderThanDays: 7);
  }

  bool _isWeekend(DateTime dt) =>
      dt.weekday == DateTime.saturday || dt.weekday == DateTime.sunday;

  String _dateString(DateTime dt) => dt.toIso8601String().substring(0, 10);
}

