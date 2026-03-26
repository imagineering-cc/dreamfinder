import 'dart:convert';

import 'package:dreamfinder/src/agent/tool_registry.dart';
import 'package:dreamfinder/src/db/database.dart';
import 'package:dreamfinder/src/db/queries.dart';
import 'package:dreamfinder/src/session/session_state.dart';
import 'package:dreamfinder/src/tools/session_tools.dart';
import 'package:test/test.dart';

void main() {
  late BotDatabase db;
  late Queries queries;
  late SessionState state;
  late ToolRegistry registry;
  late List<(String, String)> sentMessages;

  const groupId = 'test-group-id';

  setUp(() {
    db = BotDatabase.inMemory();
    queries = Queries(db);
    state = SessionState(queries: queries);
    registry = ToolRegistry();
    sentMessages = [];

    registerSessionTools(
      registry,
      state,
      sendGroupMessage: (groupId, message) async {
        sentMessages.add((groupId, message));
      },
    );
  });

  tearDown(() => db.close());

  /// Helper to execute a tool and decode the JSON result.
  Future<Map<String, dynamic>> call(
    String toolName,
    Map<String, dynamic> args,
  ) async {
    registry.setContext(ToolContext(
      senderId: 'user-1',
      isAdmin: false,
      chatId: groupId,
      isGroup: true,
    ));
    final result = await registry.executeTool(toolName, args);
    return jsonDecode(result) as Map<String, dynamic>;
  }

  group('start_session', () {
    test('creates a session', () async {
      final result = await call('start_session', {
        'group_id': groupId,
        'initiator_id': 'user-1',
      });
      expect(result['success'], isTrue);
      expect(result['phase'], equals(SessionPhase.pitch.number));
      expect(state.getActiveSession(groupId), SessionPhase.pitch);
    });

    test('stores topic when provided', () async {
      final result = await call('start_session', {
        'group_id': groupId,
        'initiator_id': 'user-1',
        'topic': 'Avatar Dreamfinder',
      });
      expect(result['success'], isTrue);
      expect(result['topic'], equals('Avatar Dreamfinder'));
    });

    test('fails if session already active', () async {
      await call('start_session', {
        'group_id': groupId,
        'initiator_id': 'user-1',
      });
      final result = await call('start_session', {
        'group_id': groupId,
        'initiator_id': 'user-1',
      });
      expect(result['success'], isFalse);
      expect(result['error'], isA<String>());
    });
  });

  group('advance_session', () {
    test('moves to next phase', () async {
      await call('start_session', {
        'group_id': groupId,
        'initiator_id': 'user-1',
      });
      final result = await call('advance_session', {'group_id': groupId});
      expect(result['success'], isTrue);
      expect(result['new_phase'], equals(SessionPhase.build1.number));
      expect(result['new_phase_label'], equals(SessionPhase.build1.label));
    });

    test('fails with no active session', () async {
      final result = await call('advance_session', {'group_id': groupId});
      expect(result['success'], isFalse);
      expect(result['error'], isA<String>());
    });

    test('advances through all phases sequentially', () async {
      await call('start_session', {
        'group_id': groupId,
        'initiator_id': 'user-1',
      });

      final expectedPhases = [
        SessionPhase.build1,
        SessionPhase.chat1,
        SessionPhase.build2,
        SessionPhase.chat2,
        SessionPhase.build3,
        SessionPhase.chat3,
        SessionPhase.demo,
      ];

      for (final expected in expectedPhases) {
        final result =
            await call('advance_session', {'group_id': groupId});
        expect(result['new_phase'], equals(expected.number),
            reason: 'Expected ${expected.label}');
      }
    });

    test('fails when already on final phase', () async {
      await call('start_session', {
        'group_id': groupId,
        'initiator_id': 'user-1',
      });
      // Advance all 7 times to reach demo.
      for (var i = 0; i < 7; i++) {
        await call('advance_session', {'group_id': groupId});
      }
      final result = await call('advance_session', {'group_id': groupId});
      expect(result['success'], isFalse);
    });
  });

  group('end_session', () {
    test('clears state and posts summary', () async {
      await call('start_session', {
        'group_id': groupId,
        'initiator_id': 'user-1',
      });
      final result = await call('end_session', {
        'group_id': groupId,
        'summary': 'Great session everyone!',
      });
      expect(result['success'], isTrue);
      expect(state.getActiveSession(groupId), isNull);
      expect(sentMessages, hasLength(1));
      expect(sentMessages.first.$1, equals(groupId));
      expect(sentMessages.first.$2, contains('Great session everyone!'));
    });

    test('fails with no active session', () async {
      final result = await call('end_session', {
        'group_id': groupId,
        'summary': 'Summary text',
      });
      expect(result['success'], isFalse);
    });
  });

  group('capture_insight', () {
    test('stores insight for a session', () async {
      await call('start_session', {
        'group_id': groupId,
        'initiator_id': 'user-1',
      });
      final result = await call('capture_insight', {
        'group_id': groupId,
        'insight': 'We should use WebRTC for the avatar feature.',
        'type': 'insight',
        'author': 'Alice',
      });
      expect(result['success'], isTrue);
      expect(result['type'], equals('insight'));
    });

    test('fails with no active session', () async {
      final result = await call('capture_insight', {
        'group_id': groupId,
        'insight': 'Some insight',
        'type': 'decision',
      });
      expect(result['success'], isFalse);
    });
  });
}
