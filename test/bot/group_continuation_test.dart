import 'package:dreamfinder/src/bot/group_continuation.dart';
import 'package:test/test.dart';

void main() {
  const chatId = 'group-abc';

  late DateTime now;
  late GroupContinuation continuation;

  setUp(() {
    now = DateTime(2026, 3, 11, 12, 0);
    continuation = GroupContinuation(
      ttl: const Duration(minutes: 5),
      clock: () => now,
    );
  });

  group('shouldContinue', () {
    test('returns false when bot has not spoken in chat', () {
      expect(continuation.shouldContinue(chatId: chatId), isFalse);
    });

    test('returns true after bot response', () {
      continuation.recordBotResponse(chatId: chatId);
      expect(continuation.shouldContinue(chatId: chatId), isTrue);
    });

    test('any group member triggers continuation', () {
      // Bot responds, then a different member messages — should still work.
      continuation.recordBotResponse(chatId: chatId);
      expect(continuation.shouldContinue(chatId: chatId), isTrue);
    });

    test('returns false after TTL expires', () {
      continuation.recordBotResponse(chatId: chatId);
      now = now.add(const Duration(minutes: 6));
      expect(continuation.shouldContinue(chatId: chatId), isFalse);
    });

    test('returns true just before TTL expires', () {
      continuation.recordBotResponse(chatId: chatId);
      now = now.add(const Duration(minutes: 4, seconds: 59));
      expect(continuation.shouldContinue(chatId: chatId), isTrue);
    });

    test('consumes the entry (second call returns false)', () {
      continuation.recordBotResponse(chatId: chatId);
      expect(continuation.shouldContinue(chatId: chatId), isTrue);
      expect(continuation.shouldContinue(chatId: chatId), isFalse);
    });

    test('re-recording extends the chain', () {
      continuation.recordBotResponse(chatId: chatId);

      // First follow-up processed.
      expect(continuation.shouldContinue(chatId: chatId), isTrue);

      // Bot responds again — record a new continuation.
      continuation.recordBotResponse(chatId: chatId);

      // Second follow-up — should still work.
      expect(continuation.shouldContinue(chatId: chatId), isTrue);
    });

    test('re-recording resets the TTL', () {
      continuation.recordBotResponse(chatId: chatId);

      // 4 minutes pass, first follow-up.
      now = now.add(const Duration(minutes: 4));
      expect(continuation.shouldContinue(chatId: chatId), isTrue);

      // Bot responds again — TTL resets.
      continuation.recordBotResponse(chatId: chatId);

      // Another 4 minutes (8 total from start, but only 4 from last response).
      now = now.add(const Duration(minutes: 4));
      expect(continuation.shouldContinue(chatId: chatId), isTrue);
    });

    test('tracks multiple chats independently', () {
      const chatB = 'group-xyz';
      continuation.recordBotResponse(chatId: chatId);
      continuation.recordBotResponse(chatId: chatB);

      expect(continuation.shouldContinue(chatId: chatId), isTrue);
      expect(continuation.shouldContinue(chatId: chatB), isTrue);
    });
  });

  group('clear', () {
    test('removes continuation state for a chat', () {
      continuation.recordBotResponse(chatId: chatId);
      continuation.clear(chatId);
      expect(continuation.shouldContinue(chatId: chatId), isFalse);
    });

    test('does not affect other chats', () {
      const chatB = 'group-xyz';
      continuation.recordBotResponse(chatId: chatId);
      continuation.recordBotResponse(chatId: chatB);
      continuation.clear(chatId);
      expect(continuation.shouldContinue(chatId: chatB), isTrue);
    });
  });

  group('evictStale', () {
    test('removes expired entries', () {
      continuation.recordBotResponse(chatId: chatId);
      now = now.add(const Duration(minutes: 6));
      continuation.evictStale();
      expect(continuation.shouldContinue(chatId: chatId), isFalse);
    });

    test('keeps non-expired entries', () {
      continuation.recordBotResponse(chatId: chatId);
      now = now.add(const Duration(minutes: 3));
      continuation.evictStale();
      expect(continuation.shouldContinue(chatId: chatId), isTrue);
    });
  });
}
