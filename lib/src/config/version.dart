/// Build version info.
///
/// These constants are overwritten by the Dockerfile at build time with the
/// actual semver, git SHA, build timestamp, and changelog. The dev defaults
/// here allow `dart run` to work without any build step.
const String appVersion = 'dev';
const String appCommit = 'local';
const String appBuildTime = 'unknown';

/// Git log of commits included in this build (baked in at Docker build time).
/// Empty in dev mode — deploy announcements are skipped when empty.
const String appChangelog = '';

/// `git diff --stat` summary of files changed (baked in at Docker build time).
const String appDiffStat = '';
