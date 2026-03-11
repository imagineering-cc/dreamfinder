/// Tracks group chats where the bot spoke last, allowing the next message
/// from **any member** to be treated as a conversation continuation without
/// requiring an explicit name mention.
///
/// State is in-memory and lost on restart — this is intentional. A restart
/// is a natural conversation break, and persisting continuation state across
/// restarts would risk ghost responses to stale context.
///
/// Each entry has a TTL so that a message arriving hours later doesn't
/// unexpectedly trigger a continuation.
library;

/// Tracks conversation continuation state for group chats.
class GroupContinuation {
  GroupContinuation({
    this.ttl = const Duration(minutes: 5),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// How long a continuation entry remains valid after the bot last spoke.
  final Duration ttl;

  /// Injectable clock for testing.
  final DateTime Function() _clock;

  /// Maps chatId → when the bot last spoke.
  final Map<String, DateTime> _entries = {};

  /// Records that the bot just responded in [chatId].
  void recordBotResponse({required String chatId}) {
    _entries[chatId] = _clock();
  }

  /// Returns `true` if the next message in [chatId] should be treated as a
  /// conversation continuation (i.e., the bot was the last speaker and the
  /// TTL hasn't expired).
  ///
  /// If this returns `true`, the entry is consumed — call [recordBotResponse]
  /// again after the bot replies to keep the chain going.
  bool shouldContinue({required String chatId}) {
    final timestamp = _entries.remove(chatId);
    if (timestamp == null) return false;

    // TTL expired — treat as a fresh conversation.
    if (_clock().difference(timestamp) > ttl) return false;

    return true;
  }

  /// Clears the continuation state for [chatId].
  void clear(String chatId) {
    _entries.remove(chatId);
  }

  /// Removes expired entries to prevent unbounded growth.
  ///
  /// Call periodically (e.g., from the main polling loop alongside
  /// [RateLimiter.evictStale]).
  void evictStale() {
    final now = _clock();
    _entries.removeWhere(
      (_, timestamp) => now.difference(timestamp) > ttl,
    );
  }
}
