/// Per-user and per-group rate limiter for incoming messages.
///
/// Two independent limits:
/// 1. **Per-user cooldown**: prevents a single user from spamming the bot.
/// 2. **Per-group window**: limits total bot responses in a group within a
///    time window, regardless of sender.
///
/// DMs (chatId starting with '+') bypass the group throttle but still
/// respect per-user cooldown.
library;

/// Rate limiter for incoming bot messages.
class RateLimiter {
  RateLimiter({
    this.perUserCooldown = const Duration(seconds: 5),
    this.perGroupWindow = const Duration(seconds: 30),
    this.maxGroupMessages = 5,
  });

  /// Minimum time between responses to the same user.
  final Duration perUserCooldown;

  /// Time window for counting group messages.
  final Duration perGroupWindow;

  /// Maximum bot responses in a group within [perGroupWindow].
  final int maxGroupMessages;

  /// Tracks the last message timestamp per user (keyed by senderUuid).
  final Map<String, DateTime> _userLastMessage = {};

  /// Tracks message timestamps per group for window-based throttling.
  final Map<String, List<DateTime>> _groupMessages = {};

  /// Returns `true` if the message should be processed, `false` if
  /// rate-limited.
  bool shouldAllow({
    required String chatId,
    required String senderUuid,
  }) {
    final now = DateTime.now();

    // Per-user cooldown check.
    final lastMessage = _userLastMessage[senderUuid];
    if (lastMessage != null && now.difference(lastMessage) < perUserCooldown) {
      return false;
    }

    // Per-group window check (skip for DMs).
    final isDm = chatId.startsWith('+');
    if (!isDm) {
      final timestamps = _groupMessages.putIfAbsent(chatId, () => []);

      // Prune old timestamps outside the window.
      timestamps.removeWhere((t) => now.difference(t) > perGroupWindow);

      if (timestamps.length >= maxGroupMessages) {
        return false;
      }

      timestamps.add(now);
    }

    _userLastMessage[senderUuid] = now;
    return true;
  }

  /// Removes stale entries from internal maps to prevent unbounded growth.
  ///
  /// Evicts user cooldown records older than [perUserCooldown] and group
  /// windows with no recent timestamps. Call periodically (e.g., from the
  /// main polling loop).
  void evictStale() {
    final now = DateTime.now();

    _userLastMessage.removeWhere(
      (_, timestamp) => now.difference(timestamp) > perUserCooldown,
    );

    _groupMessages.removeWhere((_, timestamps) {
      timestamps.removeWhere((t) => now.difference(t) > perGroupWindow);
      return timestamps.isEmpty;
    });
  }
}
