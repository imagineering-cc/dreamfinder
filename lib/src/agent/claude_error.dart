/// Classification of Claude/Anthropic API failures into recovery strategies.
///
/// River's brain talks to Claude over HTTP. Not all failures are equal: a 529
/// overloaded response should be retried, a zero-credit billing wall should not
/// (retrying just burns more failed calls), and an `invalid_grant` auth failure
/// should trigger a fallback to a different auth mode rather than a retry.
///
/// This library is intentionally pure (no I/O) so the classification logic is
/// trivially unit-testable against the real error strings we've seen in prod.
library;

/// A Claude API call that failed after the resilient wrapper exhausted its
/// recovery options (retries / auth fallback).
///
/// Thrown by the entry point's resilient `createMessage` so the surrounding
/// message-processing loop can tell a *brain* failure (already recorded in
/// health, may need escalation) apart from an unrelated processing error
/// (Matrix send failure, corrupt history, …) without re-classifying or
/// double-counting.
class ClaudeCallFailure implements Exception {
  ClaudeCallFailure(this.kind, this.cause);

  /// The classified failure kind.
  final ClaudeErrorKind kind;

  /// The original underlying error (preserved for logging).
  final Object cause;

  @override
  String toString() => 'ClaudeCallFailure($kind): $cause';
}

/// How a Claude API failure should be handled.
enum ClaudeErrorKind {
  /// Temporary — retry with backoff (429 rate limit, 5xx, network/timeout).
  transient,

  /// Authentication failure — token is bad/expired. Do NOT retry the same
  /// auth; fall back to an alternate auth mode (e.g. API key) if available.
  auth,

  /// Billing/quota wall — e.g. "credit balance is too low". Retrying is
  /// pointless and wasteful; escalate to a human.
  billing,

  /// Anything else — non-retryable, escalate.
  other;

  /// Whether River should retry the call (with backoff) on this kind.
  bool get isRetryable => this == ClaudeErrorKind.transient;

  /// Whether this represents a capability outage worth alerting a human about.
  ///
  /// `billing` and `auth` mean River genuinely can't think; `transient`
  /// usually self-heals via retry, and `other` is escalated as a catch-all.
  bool get isCapabilityFailure =>
      this == ClaudeErrorKind.billing ||
      this == ClaudeErrorKind.auth ||
      this == ClaudeErrorKind.other;
}

/// Transient HTTP status codes that warrant a retry with backoff.
const _transientCodes = {429, 500, 502, 503, 504, 529};

/// Classifies an [error] (typically an `AnthropicClientException`, a
/// `StateError` from the OAuth refresh, or a network exception) into a
/// [ClaudeErrorKind].
///
/// The classifier inspects:
/// - an HTTP status [code] if the error exposes one (duck-typed via
///   [extractHttpCode]), and
/// - the error's string form (`toString()`), which for
///   `AnthropicClientException` includes the response body.
///
/// Order matters: billing is checked before auth before transient, because the
/// credit-balance wall surfaces as an HTTP 400 (which would otherwise look like
/// a generic client error) and we never want to retry it.
ClaudeErrorKind classifyClaudeError(Object error, {int? code}) {
  final httpCode = code ?? extractHttpCode(error);
  final text = error.toString().toLowerCase();

  // Billing wall — the exact prod failure: HTTP 400 with a body containing
  // "Your credit balance is too low". Must be caught before the generic
  // client-error path so it's never retried.
  if (text.contains('credit balance')) {
    return ClaudeErrorKind.billing;
  }

  // Auth failures: 401/403, or OAuth refresh failures (`invalid_grant`).
  if (httpCode == 401 ||
      httpCode == 403 ||
      text.contains('invalid_grant') ||
      text.contains('authentication') ||
      text.contains('refresh token not found')) {
    return ClaudeErrorKind.auth;
  }

  // Transient: rate limits, server errors, and network-level failures.
  if (httpCode != null && _transientCodes.contains(httpCode)) {
    return ClaudeErrorKind.transient;
  }
  if (text.contains('socketexception') ||
      text.contains('timeout') ||
      text.contains('timed out') ||
      text.contains('connection closed') ||
      text.contains('connection refused') ||
      text.contains('connection reset') ||
      text.contains('handshakeexception') ||
      // `http`'s ClientException for transport-level failures. Match the
      // standalone form, not the substring inside `AnthropicClientException`
      // (whose body could be any unrelated 4xx).
      text.contains(' clientexception') ||
      text.startsWith('clientexception')) {
    return ClaudeErrorKind.transient;
  }

  return ClaudeErrorKind.other;
}

/// Decides whether River should fall back from OAuth to the API key.
///
/// The prod incident that motivated this: a bad refresh token made every call
/// fail with `invalid_grant`, taking River fully offline. If an API key is also
/// configured, an `auth` failure under OAuth should degrade to the metered API
/// key rather than going dark.
///
/// Returns `true` only when ALL of:
/// - OAuth is the active auth mode ([oauthActive]),
/// - we haven't already fallen back ([alreadyFellBack] is false, to avoid
///   thrashing the client back and forth), and
/// - an API key is available ([hasApiKey]),
/// - for an [ClaudeErrorKind.auth] failure.
bool shouldFallBackToApiKey({
  required ClaudeErrorKind kind,
  required bool oauthActive,
  required bool alreadyFellBack,
  required bool hasApiKey,
}) =>
    kind == ClaudeErrorKind.auth &&
    oauthActive &&
    !alreadyFellBack &&
    hasApiKey;

/// Best-effort extraction of an HTTP status code from an arbitrary error.
///
/// `AnthropicClientException` exposes a nullable `code` field; we duck-type it
/// via a dynamic access guarded by try/catch so this library doesn't need a
/// hard dependency on the SDK type (keeping it pure and easy to test).
int? extractHttpCode(Object error) {
  try {
    // ignore: avoid_dynamic_calls
    final dynamic code = (error as dynamic).code;
    if (code is int) return code;
  } on Object {
    // Error type has no `code` getter — fall through.
  }
  return null;
}
