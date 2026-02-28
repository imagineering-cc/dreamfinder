import 'dart:convert';

import 'package:imagineering_pm_bot/src/agent/tool_registry.dart';
import 'package:imagineering_pm_bot/src/db/database.dart';
import 'package:imagineering_pm_bot/src/db/queries.dart';
import 'package:imagineering_pm_bot/src/tools/bot_identity_tools.dart';
import 'package:test/test.dart';

void main() {
  late BotDatabase db;
  late Queries queries;
  late ToolRegistry registry;

  setUp(() {
    db = BotDatabase.inMemory();
    queries = Queries(db);
    registry = ToolRegistry();
    registerBotIdentityTools(registry, queries);
  });

  tearDown(() {
    db.close();
  });

  group('get_bot_identity', () {
    test('returns defaults when no identity is set', () async {
      final result = await registry.executeTool('get_bot_identity', {});
      final data = jsonDecode(result) as Map<String, dynamic>;

      expect(data['name'], equals('Figment'));
      expect(data['pronouns'], equals('they/them'));
      expect(data['tone'], equals('Playful, imaginative, and helpful'));
      expect(data['chosen_at'], isNull);
    });

    test('returns saved identity from database', () async {
      queries.saveBotIdentity(
        name: 'Spark',
        pronouns: 'she/her',
        tone: 'enthusiastic',
        toneDescription: 'Always excited about new ideas',
      );

      final result = await registry.executeTool('get_bot_identity', {});
      final data = jsonDecode(result) as Map<String, dynamic>;

      expect(data['name'], equals('Spark'));
      expect(data['pronouns'], equals('she/her'));
      expect(data['tone'], equals('enthusiastic'));
      expect(
          data['tone_description'], equals('Always excited about new ideas'));
    });

    test('returns latest identity when multiple exist', () async {
      queries.saveBotIdentity(
        name: 'OldBot',
        pronouns: 'it/its',
        tone: 'robotic',
      );
      queries.saveBotIdentity(
        name: 'NewBot',
        pronouns: 'he/him',
        tone: 'casual',
      );

      final result = await registry.executeTool('get_bot_identity', {});
      final data = jsonDecode(result) as Map<String, dynamic>;
      expect(data['name'], equals('NewBot'));
    });
  });

  group('set_bot_identity', () {
    test('saves a new identity', () async {
      final result = await registry.executeTool('set_bot_identity', {
        'name': 'Pixel',
        'pronouns': 'they/them',
        'tone': 'quirky',
      });
      final data = jsonDecode(result) as Map<String, dynamic>;

      expect(data['success'], isTrue);
      expect(data['name'], equals('Pixel'));

      // Verify it persisted.
      final identity = queries.getBotIdentity();
      expect(identity!.name, equals('Pixel'));
      expect(identity.tone, equals('quirky'));
    });

    test('saves with optional fields', () async {
      await registry.executeTool('set_bot_identity', {
        'name': 'Gizmo',
        'pronouns': 'ze/zir',
        'tone': 'formal',
        'tone_description': 'Speaks like a Victorian butler',
        'chosen_in_group_id': 'group-123',
      });

      final identity = queries.getBotIdentity();
      expect(
          identity!.toneDescription, equals('Speaks like a Victorian butler'));
      expect(identity.chosenInGroupId, equals('group-123'));
    });
  });
}
