import 'package:dreamfinder/src/bot/deploy_announcer.dart';
import 'package:dreamfinder/src/db/database.dart';
import 'package:dreamfinder/src/db/queries.dart';
import 'package:test/test.dart';

void main() {
  late BotDatabase db;
  late Queries queries;
  late List<(String, String)> sentMessages;
  late List<(String, String)> agentCalls;

  setUp(() {
    db = BotDatabase.inMemory();
    queries = Queries(db);
    sentMessages = [];
    agentCalls = [];
  });

  tearDown(() => db.close());

  DeployAnnouncer _createAnnouncer({
    String currentVersion = 'v1.1+def456',
    String changelog = '- feat: add OAuth\n- fix: token rotation',
    String diffStat = ' lib/src/config/oauth.dart | 200 +\n 2 files changed',
    String groupId = 'group.test123',
    Future<String> Function(String, String)? composeViaAgent,
  }) =>
      DeployAnnouncer(
        queries: queries,
        composeViaAgent: composeViaAgent ??
            (gid, prompt) async {
              agentCalls.add((gid, prompt));
              return 'I have been reimagined!';
            },
        sendMessage: (gid, msg) async => sentMessages.add((gid, msg)),
        currentVersion: currentVersion,
        changelog: changelog,
        diffStat: diffStat,
        groupId: groupId,
      );

  group('DeployAnnouncer', () {
    test('first deploy seeds version without announcing', () async {
      final announcer = _createAnnouncer();

      final result = await announcer.announceIfNewVersion();

      expect(result, isFalse);
      expect(sentMessages, isEmpty);
      expect(agentCalls, isEmpty);
      expect(
        queries.getMetadata('last_deployed_version'),
        'v1.1+def456',
      );
    });

    test('same version does not announce', () async {
      queries.setMetadata('last_deployed_version', 'v1.1+def456');
      final announcer = _createAnnouncer(currentVersion: 'v1.1+def456');

      final result = await announcer.announceIfNewVersion();

      expect(result, isFalse);
      expect(sentMessages, isEmpty);
      expect(agentCalls, isEmpty);
    });

    test('new version composes and sends announcement', () async {
      queries.setMetadata('last_deployed_version', 'v1.0+abc123');
      final announcer = _createAnnouncer();

      final result = await announcer.announceIfNewVersion();

      expect(result, isTrue);
      expect(agentCalls, hasLength(1));
      expect(agentCalls.first.$1, 'group.test123');
      expect(agentCalls.first.$2, contains('OAuth'));
      expect(agentCalls.first.$2, contains('Changelog'));
      expect(sentMessages, hasLength(1));
      expect(sentMessages.first.$1, 'group.test123');
      expect(sentMessages.first.$2, 'I have been reimagined!');
      expect(
        queries.getMetadata('last_deployed_version'),
        'v1.1+def456',
      );
    });

    test('agent failure still updates version', () async {
      queries.setMetadata('last_deployed_version', 'v1.0+old');
      final announcer = _createAnnouncer(
        composeViaAgent: (_, __) async => throw Exception('API down'),
      );

      final result = await announcer.announceIfNewVersion();

      expect(result, isFalse);
      expect(sentMessages, isEmpty);
      expect(
        queries.getMetadata('last_deployed_version'),
        'v1.1+def456',
      );
    });

    test('empty composition does not send message', () async {
      queries.setMetadata('last_deployed_version', 'v1.0+old');
      final announcer = _createAnnouncer(
        composeViaAgent: (_, __) async => '',
      );

      final result = await announcer.announceIfNewVersion();

      // Version updated but no message sent.
      expect(result, isTrue);
      expect(sentMessages, isEmpty);
      expect(
        queries.getMetadata('last_deployed_version'),
        'v1.1+def456',
      );
    });

    test('prompt includes changelog and diff stat', () async {
      queries.setMetadata('last_deployed_version', 'v1.0+old');
      final announcer = _createAnnouncer(
        changelog: 'abc123 feat: awesome feature',
        diffStat: ' lib/awesome.dart | 50 +',
      );

      await announcer.announceIfNewVersion();

      expect(agentCalls.first.$2, contains('abc123 feat: awesome feature'));
      expect(agentCalls.first.$2, contains('lib/awesome.dart'));
    });
  });
}
