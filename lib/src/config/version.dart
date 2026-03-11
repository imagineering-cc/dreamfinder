/// Build version info.
///
/// These constants are overwritten by the Dockerfile at build time with the
/// actual semver, git SHA, and build timestamp. The dev defaults here allow
/// `dart run` to work without any build step.
const String appVersion = 'dev';
const String appCommit = 'local';
const String appBuildTime = 'unknown';
