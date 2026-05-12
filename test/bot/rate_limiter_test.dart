import 'package:dreamfinder/src/bot/rate_limiter.dart';
import 'package:test/test.dart';

void main() {
  group('RateLimiter', () {
    test('allows first message from a sender', () {
      final limiter = RateLimiter(
        perUserCooldown: const Duration(seconds: 5),
        perGroupWindow: const Duration(seconds: 10),
        maxGroupMessages: 3,
      );

      expect(
          limiter.shouldAllow(chatId: 'group-1', senderId: 'user-1'), isTrue);
    });

    test('blocks rapid messages from the same sender', () {
      final limiter = RateLimiter(
        perUserCooldown: const Duration(seconds: 5),
        perGroupWindow: const Duration(seconds: 10),
        maxGroupMessages: 10,
      );

      expect(
          limiter.shouldAllow(chatId: 'group-1', senderId: 'user-1'), isTrue);
      expect(
          limiter.shouldAllow(chatId: 'group-1', senderId: 'user-1'), isFalse);
    });

    test('allows different senders within cooldown', () {
      final limiter = RateLimiter(
        perUserCooldown: const Duration(seconds: 5),
        perGroupWindow: const Duration(seconds: 10),
        maxGroupMessages: 10,
      );

      expect(
          limiter.shouldAllow(chatId: 'group-1', senderId: 'user-1'), isTrue);
      expect(
          limiter.shouldAllow(chatId: 'group-1', senderId: 'user-2'), isTrue);
    });

    test('blocks when group message limit is exceeded', () {
      final limiter = RateLimiter(
        perUserCooldown: Duration.zero,
        perGroupWindow: const Duration(seconds: 60),
        maxGroupMessages: 2,
      );

      expect(
          limiter.shouldAllow(chatId: 'group-1', senderId: 'user-1'), isTrue);
      expect(
          limiter.shouldAllow(chatId: 'group-1', senderId: 'user-2'), isTrue);
      // Third message in the window — should be blocked.
      expect(
          limiter.shouldAllow(chatId: 'group-1', senderId: 'user-3'), isFalse);
    });

    test('isolates rate limits between groups', () {
      final limiter = RateLimiter(
        perUserCooldown: Duration.zero,
        perGroupWindow: const Duration(seconds: 60),
        maxGroupMessages: 1,
      );

      expect(
          limiter.shouldAllow(chatId: 'group-1', senderId: 'user-1'), isTrue);
      // Different group — independent limit.
      expect(
          limiter.shouldAllow(chatId: 'group-2', senderId: 'user-1'), isTrue);
    });

    test('allows DMs without group throttling', () {
      final limiter = RateLimiter(
        perUserCooldown: Duration.zero,
        perGroupWindow: const Duration(seconds: 60),
        maxGroupMessages: 1,
      );

      // DMs bypass group throttle when isDm is true.
      expect(
          limiter.shouldAllow(
              chatId: '!dm-room:server', senderId: 'user-1', isDm: true),
          isTrue);
      expect(
          limiter.shouldAllow(
              chatId: '!dm-room:server', senderId: 'user-1', isDm: true),
          isTrue);
    });

    test('allows message after cooldown expires', () async {
      final limiter = RateLimiter(
        perUserCooldown: const Duration(milliseconds: 50),
        perGroupWindow: const Duration(seconds: 60),
        maxGroupMessages: 100,
      );

      expect(
          limiter.shouldAllow(chatId: 'group-1', senderId: 'user-1'), isTrue);
      expect(
          limiter.shouldAllow(chatId: 'group-1', senderId: 'user-1'), isFalse);

      // Wait for cooldown to expire.
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(
          limiter.shouldAllow(chatId: 'group-1', senderId: 'user-1'), isTrue);
    });

    test('custom values are respected', () {
      // Construct with non-default values and verify they take effect.
      final limiter = RateLimiter(
        perUserCooldown: const Duration(seconds: 1),
        perGroupWindow: const Duration(seconds: 30),
        maxGroupMessages: 20,
      );

      expect(limiter.perUserCooldown, equals(const Duration(seconds: 1)));
      expect(limiter.maxGroupMessages, equals(20));
      expect(limiter.perGroupWindow, equals(const Duration(seconds: 30)));

      // With maxGroupMessages=20, 10 different senders should all be allowed.
      for (var i = 0; i < 10; i++) {
        expect(
          limiter.shouldAllow(chatId: 'group-demo', senderId: 'user-$i'),
          isTrue,
          reason: 'user-$i should be allowed under a 20-message group cap',
        );
      }
    });

    test('uses defaults when constructed without arguments', () {
      final limiter = RateLimiter();

      expect(limiter.perUserCooldown, equals(const Duration(seconds: 5)));
      expect(limiter.maxGroupMessages, equals(5));
      expect(limiter.perGroupWindow, equals(const Duration(seconds: 30)));
    });

    test('evictStale removes expired user and group entries', () async {
      final limiter = RateLimiter(
        perUserCooldown: const Duration(milliseconds: 50),
        perGroupWindow: const Duration(milliseconds: 50),
        maxGroupMessages: 10,
      );

      limiter.shouldAllow(chatId: 'group-1', senderId: 'user-1');
      limiter.shouldAllow(chatId: 'group-2', senderId: 'user-2');

      // Wait for everything to expire, then evict.
      await Future<void>.delayed(const Duration(milliseconds: 60));
      limiter.evictStale();

      // After eviction, the same users/groups should be allowed again
      // (entries were cleaned up, not just expired naturally).
      expect(
          limiter.shouldAllow(chatId: 'group-1', senderId: 'user-1'), isTrue);
      expect(
          limiter.shouldAllow(chatId: 'group-2', senderId: 'user-2'), isTrue);
    });
  });
}
