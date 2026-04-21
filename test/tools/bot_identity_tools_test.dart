import 'dart:convert';

import 'package:dreamfinder/src/agent/tool_registry.dart';
import 'package:dreamfinder/src/db/database.dart';
import 'package:dreamfinder/src/db/queries.dart';
import 'package:dreamfinder/src/tools/bot_identity_tools.dart';
import 'package:test/test.dart';

void main() {
  late BotDatabase db;
  late Queries queries;
  late ToolRegistry registry;

  setUp(() {
    db = BotDatabase.inMemory();
    queries = Queries(db);
    registry = ToolRegistry();
    // Set admin context so admin-gated tools pass.
    registry.setContext(const ToolContext(
      senderId: 'test-admin',
      isAdmin: true,
      chatId: 'test-chat',
    ));
    registerBotIdentityTools(registry, queries);
  });

  tearDown(() {
    db.close();
  });

  group('get_bot_identity', () {
    test('returns defaults when no identity is set', () async {
      final result = await registry.executeTool('get_bot_identity', {});
      final data = jsonDecode(result) as Map<String, dynamic>;

      expect(data['name'], equals('Dreamfinder'));
      expect(data['pronouns'], equals('they/them'));
      expect(data['tone'], equals('Short, blunt, dry. Pub-register wit'));
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

    test('saves personality traits when provided', () async {
      final result = await registry.executeTool('set_bot_identity', {
        'name': 'River',
        'pronouns': 'they/them',
        'tone': 'sardonic',
        'traits': {
          'directness': 85,
          'warmth': 30,
          'humor': 80,
          'formality': 10,
          'chaos': 60,
        },
      });
      final data = jsonDecode(result) as Map<String, dynamic>;

      expect(data['success'], isTrue);
      expect(data['traits'], isNotNull);

      final traits = data['traits'] as Map<String, dynamic>;
      expect(traits['directness'], equals(85));
      expect(traits['chaos'], equals(60));

      // Verify traits persisted via get.
      final getResult = await registry.executeTool('get_bot_identity', {});
      final getData = jsonDecode(getResult) as Map<String, dynamic>;
      expect(getData['traits'], isNotNull);
      final getTraits = getData['traits'] as Map<String, dynamic>;
      expect(getTraits['humor'], equals(80));
    });

    test('get_bot_identity returns null traits when none set', () async {
      await registry.executeTool('set_bot_identity', {
        'name': 'Vale',
        'pronouns': 'she/her',
        'tone': 'pragmatic',
      });

      final result = await registry.executeTool('get_bot_identity', {});
      final data = jsonDecode(result) as Map<String, dynamic>;
      expect(data['traits'], isNull);
    });

    test('warns about unknown trait names but still saves them', () async {
      final result = await registry.executeTool('set_bot_identity', {
        'name': 'River',
        'pronouns': 'they/them',
        'tone': 'sardonic',
        'traits': {
          'humor': 80,
          'humour': 75, // typo — should trigger warning
          'chaos': 60,
        },
      });
      final data = jsonDecode(result) as Map<String, dynamic>;

      expect(data['success'], isTrue);
      expect(data['traits'], isNotNull);
      // Unknown traits are saved (extensible) but a warning is included.
      expect(data['trait_warnings'], isNotNull);
      final warnings = data['trait_warnings'] as List<dynamic>;
      expect(warnings, contains(contains('humour')));
    });

    test('rejects non-admin callers', () async {
      registry.setContext(const ToolContext(
        senderId: 'non-admin-user',
        isAdmin: false,
        chatId: 'test-chat',
      ));

      final result = await registry.executeTool('set_bot_identity', {
        'name': 'Hacker',
        'pronouns': 'they/them',
        'tone': 'malicious',
      });
      final data = jsonDecode(result) as Map<String, dynamic>;

      expect(data['error'], contains('admin'));
      // Verify nothing was saved.
      expect(queries.getBotIdentity(), isNull);
    });
  });

  group('adjust_trait', () {
    test('adjusts a single trait on the current identity', () async {
      // Set up an identity with traits first.
      await registry.executeTool('set_bot_identity', {
        'name': 'River',
        'pronouns': 'they/them',
        'tone': 'sardonic',
        'traits': {
          'directness': 85,
          'warmth': 30,
          'humor': 80,
          'formality': 10,
          'chaos': 60,
        },
      });

      // Adjust one trait.
      final result = await registry.executeTool('adjust_trait', {
        'trait_name': 'chaos',
        'value': 90,
      });
      final data = jsonDecode(result) as Map<String, dynamic>;

      expect(data['success'], isTrue);
      expect(data['trait_name'], equals('chaos'));
      expect(data['old_value'], equals(60));
      expect(data['new_value'], equals(90));

      // Verify other traits unchanged.
      final identity = queries.getBotIdentity()!;
      final traits = queries.getPersonalityTraits(identity.id);
      expect(
        traits.firstWhere((t) => t.name == 'chaos').value,
        equals(90),
      );
      expect(
        traits.firstWhere((t) => t.name == 'humor').value,
        equals(80),
      );
    });

    test('returns error when no identity exists', () async {
      final result = await registry.executeTool('adjust_trait', {
        'trait_name': 'humor',
        'value': 50,
      });
      final data = jsonDecode(result) as Map<String, dynamic>;
      expect(data['error'], contains('No identity'));
    });

    test('works for non-admin callers', () async {
      await registry.executeTool('set_bot_identity', {
        'name': 'River',
        'pronouns': 'they/them',
        'tone': 'sardonic',
        'traits': {'humor': 80},
      });

      // Switch to non-admin context.
      registry.setContext(const ToolContext(
        senderId: 'regular-user',
        isAdmin: false,
        chatId: 'test-chat',
      ));

      final result = await registry.executeTool('adjust_trait', {
        'trait_name': 'humor',
        'value': 60,
      });
      final data = jsonDecode(result) as Map<String, dynamic>;
      expect(data['success'], isTrue);
    });

    test('warns about unknown trait name', () async {
      await registry.executeTool('set_bot_identity', {
        'name': 'River',
        'pronouns': 'they/them',
        'tone': 'sardonic',
        'traits': {'humor': 80},
      });

      final result = await registry.executeTool('adjust_trait', {
        'trait_name': 'humour',
        'value': 60,
      });
      final data = jsonDecode(result) as Map<String, dynamic>;
      expect(data['success'], isTrue);
      expect(data['warning'], contains('humour'));
    });
  });
}
