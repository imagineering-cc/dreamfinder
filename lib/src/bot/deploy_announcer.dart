/// Self-announcing deploy: Dreamfinder reads its own source code changes
/// and announces its reimagining to the Signal group in its own voice.
///
/// On startup, if the version has changed since last deploy, the bot:
/// 1. Reads baked-in changelog and diff stat (compiled into the binary)
/// 2. Routes them through the agent loop with a reflective prompt
/// 3. Sends the composed announcement to the configured Signal group
/// 4. Persists the new version so it doesn't re-announce on restart
library;

import '../cron/scheduler.dart' show ComposeViaAgentFn, SendMessageFn;
import '../db/queries.dart';
import '../logging/logger.dart';

const _metadataKey = 'last_deployed_version';

/// Announces new deploys by having Dreamfinder reflect on its own changes.
class DeployAnnouncer {
  DeployAnnouncer({
    required this.queries,
    required this.composeViaAgent,
    required this.sendMessage,
    required this.currentVersion,
    required this.changelog,
    required this.diffStat,
    required this.groupId,
    this.log,
  });

  final Queries queries;
  final ComposeViaAgentFn composeViaAgent;
  final SendMessageFn sendMessage;
  final String currentVersion;
  final String changelog;
  final String diffStat;
  final String groupId;
  final BotLogger? log;

  /// Checks for a version change and announces if needed.
  ///
  /// Returns `true` if the version changed (regardless of whether the
  /// announcement succeeded — the version is always updated to prevent
  /// retries on restart).
  Future<bool> announceIfNewVersion() async {
    final lastVersion = queries.getMetadata(_metadataKey);

    if (lastVersion == null) {
      // First deploy — seed the version without announcing.
      queries.setMetadata(_metadataKey, currentVersion);
      log?.info('First deploy — seeded version', extra: {
        'version': currentVersion,
      });
      return false;
    }

    if (lastVersion == currentVersion) return false;

    log?.info('Version changed', extra: {
      'from': lastVersion,
      'to': currentVersion,
    });

    // Version changed — compose and send announcement.
    try {
      final message = await composeViaAgent(groupId, _buildPrompt());
      if (message.isNotEmpty) {
        await sendMessage(groupId, message);
      }
    } on Exception catch (e) {
      // Non-critical — log and continue. The bot should start regardless.
      log?.warning('Deploy announcement failed: $e');
      queries.setMetadata(_metadataKey, currentVersion);
      return false;
    }

    queries.setMetadata(_metadataKey, currentVersion);
    return true;
  }

  String _buildPrompt() {
    final buffer = StringBuffer()
      ..writeln('You have just been redeployed with a new version.')
      ..writeln('Announce your reimagining to the group.')
      ..writeln()
      ..writeln('Here is what changed in your source code:')
      ..writeln()
      ..writeln('## Changelog')
      ..writeln(changelog)
      ..writeln()
      ..writeln('## Files Changed')
      ..writeln(diffStat)
      ..writeln()
      ..writeln(
        'Reflect on these changes as if they are your own evolution. '
        'Be brief, personal, and in-character. '
        'Do not list every commit — pick out what feels meaningful. '
        'You are discovering your own transformation.',
      );
    return buffer.toString();
  }
}
