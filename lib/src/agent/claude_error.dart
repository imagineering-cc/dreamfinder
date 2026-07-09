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

/// A user-facing, in-character line explaining a Claude failure — funny but
/// honest. River wears the Australian-pub register (cf. the "brain's gone
/// walkabout" alert), and every kind names *what actually broke* so the reader
/// isn't left with a blank "something went wrong". The specific technical cause
/// is appended separately by the caller (see bin/dreamfinder.dart).
String claudeErrorUserMessage(ClaudeErrorKind kind) => switch (kind) {
      ClaudeErrorKind.billing =>
        "Bit awkward, this — my account's out of credit, so I literally can't afford a thought right now. Someone shout the Anthropic bill and I'll be a genius again.",
      ClaudeErrorKind.auth =>
        "My Claude credentials just got knocked back — someone needs to re-up the auth (the login or the API key). I'm locked out of my own head till then.",
      ClaudeErrorKind.transient =>
        "Claude's unreachable or rate-limiting me — throttled, or the servers are cactus (a 429/5xx, a timeout, or a dropped connection). I gave it a few goes and it's still stroppy. Poke me again in a tick.",
      ClaudeErrorKind.other =>
        "Something upstairs misfired, and it wasn't the usual suspects. Give it another crack — and if I keep flaking, poke Nick.",
    };

/// The single room-safe rendering of an exception: redact secrets on the
/// **full** text, **then** shorten. This is the one door a room-bound error
/// string goes through — never hand a raw or pre-truncated cause to a
/// multi-party channel. Truncating first can slice a secret so a fragment
/// slips past the patterns (cage-match: truncate-then-redact leaked). Callers
/// that build a user-facing error string for a Matrix room use this, not
/// `redactSecrets` composed with an external truncator.
String roomSafeErrorDetail(Object error, {int maxLength = 200}) {
  final redacted = redactSecrets(error.toString().replaceAll('\n', ' ').trim());
  return redacted.length > maxLength
      ? '${redacted.substring(0, maxLength)}…'
      : redacted;
}

/// Masks secret-looking substrings before an error detail is shown to users in
/// a chat room. Error text (esp. non-Claude exceptions) can carry a bearer
/// token, JWT, API key, URL credential, or auth header that must not land in
/// durable room history. It keeps the *informative* part (status, message)
/// while masking the dangerous part.
///
/// Defence in depth, not a perfect filter: it **fails closed** by over-redacting
/// long opaque runs (a request-id or UUID may be masked) — at a multi-party
/// boundary a lost correlation handle beats a leaked key. Always run it via
/// [roomSafeErrorDetail] so redaction precedes truncation.
String redactSecrets(String s) => s
    // JWTs: header.payload.signature, always starting `eyJ` (base64url of `{"`).
    // Matched first so the dotted blob isn't split by the opaque rule below.
    .replaceAll(
        RegExp(r'\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9._-]+'), '<redacted-jwt>')
    // Authorization header, ANY scheme (Bearer/Basic/Token/Digest/…) — mask the
    // whole credential. A Bearer-only rule leaked `Basic`/`Token` creds; the
    // generic label rule below only ate the scheme word (cage-match r2). Runs
    // before the label rule so `authorization` is handled here, not there.
    .replaceAll(
        RegExp(
            r'''\b(authorization)["']?\s*[:=]\s*["']?(?:[A-Za-z]+\s+)?[A-Za-z0-9._~+/=:-]{3,}''',
            caseSensitive: false),
        r'authorization=<redacted>')
    // Bare `Bearer <tok>` with no `Authorization:` label.
    .replaceAllMapped(
        RegExp(r'\b(bearer)\s+[A-Za-z0-9._~+/=-]{6,}', caseSensitive: false),
        (m) => '${m[1]} <redacted>')
    // AWS access key id: AKIA + 16 upper/digits, no separator.
    .replaceAll(RegExp(r'\bAKIA[0-9A-Z]{16}\b'), '<redacted-token>')
    // Known provider token prefixes (separator-delimited).
    .replaceAll(
        RegExp(
            r'\b(sk|pa|xox[bpacsr]|xapp|gh[porsu]|github_pat|glpat|npm)[-_][A-Za-z0-9._-]{8,}'),
        '<redacted-token>')
    // label=value / label: value — keep the label, mask the value. The value
    // alternation treats a quoted string as ATOMIC (incl. internal commas /
    // semicolons), so a JSON `"secret": "foo,bar;baz"` no longer leaks its tail
    // (cage-match r2); an unquoted value stops at the first delimiter.
    // (…including the Digest-auth secret params `response`/`nonce`/`cnonce`,
    // whose comma-separated quoted values the any-scheme rule above can't eat as
    // a unit — here the atomic quoted capture masks each credential precisely,
    // cage-match r3. Non-secret Digest params like username/realm/uri may remain
    // — they are not credentials.)
    .replaceAllMapped(
        RegExp(
            r'''\b(bearer|api[-_]?key|access[-_]?key|secret|client[-_]?secret|refresh[-_]?token|access[-_]?token|private[-_]?key|password|passwd|pwd|token|cookie|session|response|nonce|cnonce)["']?\s*[:=]\s*(?:"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|[^\s,;&}]+)''',
            caseSensitive: false),
        (m) => '${m[1]}=<redacted>')
    // Credentials embedded in a URL (https://user:pass@host).
    .replaceAll(RegExp(r'://[^/\s:@]+:[^/\s@]+@'), '://<redacted>@')
    // Catch-all: long opaque runs (keys, base64, hex). No `\b` anchor — `\b` is
    // defined on `\w` and fails at a base64 `+`/`/` edge, letting real keys slip
    // (cage-match). Over-redacts long ids by design (fail closed).
    .replaceAll(RegExp(r'[A-Za-z0-9+/=_-]{32,}'), '<redacted>');

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
