import 'package:dreamfinder/src/agent/claude_error.dart';
import 'package:test/test.dart';

/// Minimal stand-in for `AnthropicClientException`: carries an HTTP [code] and
/// a [body] that surfaces in `toString()`, exactly like the real SDK type.
class _FakeAnthropicException implements Exception {
  _FakeAnthropicException({this.code, required this.body});

  final int? code;
  final String body;

  @override
  String toString() => 'AnthropicClientException(code: $code, body: $body)';
}

void main() {
  group('classifyClaudeError', () {
    test('billing: credit-balance 400 (the prod failure)', () {
      // The literal body Anthropic returns when credits hit zero.
      final err = _FakeAnthropicException(
        code: 400,
        body: '{"type":"error","error":{"type":"invalid_request_error",'
            '"message":"Your credit balance is too low to access the '
            'Anthropic API. Please go to Plans & Billing to upgrade or '
            'purchase credits."}}',
      );
      expect(classifyClaudeError(err), ClaudeErrorKind.billing);
      // Billing must never be retryable, even though code is a 4xx.
      expect(ClaudeErrorKind.billing.isRetryable, isFalse);
    });

    test('auth: OAuth invalid_grant refresh failure', () {
      final err = StateError(
        'OAuth token refresh failed (400): '
        '{"error":"invalid_grant","error_description":'
        '"Refresh token not found or invalid"}',
      );
      expect(classifyClaudeError(err), ClaudeErrorKind.auth);
    });

    test('auth: HTTP 401', () {
      final err = _FakeAnthropicException(code: 401, body: 'unauthorized');
      expect(classifyClaudeError(err), ClaudeErrorKind.auth);
    });

    test('auth: HTTP 403', () {
      final err = _FakeAnthropicException(code: 403, body: 'forbidden');
      expect(classifyClaudeError(err), ClaudeErrorKind.auth);
    });

    test('auth: authentication keyword in body', () {
      final err = _FakeAnthropicException(
        code: 400,
        body: '{"error":{"type":"authentication_error",'
            '"message":"invalid x-api-key"}}',
      );
      expect(classifyClaudeError(err), ClaudeErrorKind.auth);
    });

    test('transient: 429 rate limit', () {
      final err = _FakeAnthropicException(code: 429, body: 'rate_limit');
      expect(classifyClaudeError(err), ClaudeErrorKind.transient);
      expect(ClaudeErrorKind.transient.isRetryable, isTrue);
    });

    test('transient: 529 overloaded', () {
      final err = _FakeAnthropicException(code: 529, body: 'overloaded_error');
      expect(classifyClaudeError(err), ClaudeErrorKind.transient);
    });

    test('transient: 500/502/503', () {
      for (final code in [500, 502, 503]) {
        final err = _FakeAnthropicException(code: code, body: 'server error');
        expect(classifyClaudeError(err), ClaudeErrorKind.transient,
            reason: 'code $code should be transient');
      }
    });

    test('transient: SocketException (network)', () {
      final err = Exception(
        'SocketException: Connection refused (OS Error: ...)',
      );
      expect(classifyClaudeError(err), ClaudeErrorKind.transient);
    });

    test('transient: timeout', () {
      final err = Exception('Request timed out after 30s');
      expect(classifyClaudeError(err), ClaudeErrorKind.transient);
    });

    test('transient: connection closed', () {
      final err = Exception(
        'ClientException: Connection closed before full header was received',
      );
      expect(classifyClaudeError(err), ClaudeErrorKind.transient);
    });

    test('other: unrecognised 400', () {
      final err = _FakeAnthropicException(
        code: 400,
        body: '{"error":{"type":"invalid_request_error",'
            '"message":"max_tokens too large"}}',
      );
      expect(classifyClaudeError(err), ClaudeErrorKind.other);
      expect(ClaudeErrorKind.other.isRetryable, isFalse);
    });

    test('explicit code arg overrides extraction', () {
      final err = Exception('opaque error with no code');
      expect(classifyClaudeError(err, code: 503), ClaudeErrorKind.transient);
    });

    test('isCapabilityFailure: billing/auth/other yes, transient no', () {
      expect(ClaudeErrorKind.billing.isCapabilityFailure, isTrue);
      expect(ClaudeErrorKind.auth.isCapabilityFailure, isTrue);
      expect(ClaudeErrorKind.other.isCapabilityFailure, isTrue);
      expect(ClaudeErrorKind.transient.isCapabilityFailure, isFalse);
    });
  });

  group('shouldFallBackToApiKey', () {
    test('auth under OAuth with an API key and no prior fallback → true', () {
      expect(
        shouldFallBackToApiKey(
          kind: ClaudeErrorKind.auth,
          oauthActive: true,
          alreadyFellBack: false,
          hasApiKey: true,
        ),
        isTrue,
      );
    });

    test('no fallback when already fell back (anti-thrash)', () {
      expect(
        shouldFallBackToApiKey(
          kind: ClaudeErrorKind.auth,
          oauthActive: true,
          alreadyFellBack: true,
          hasApiKey: true,
        ),
        isFalse,
      );
    });

    test('no fallback without an API key', () {
      expect(
        shouldFallBackToApiKey(
          kind: ClaudeErrorKind.auth,
          oauthActive: true,
          alreadyFellBack: false,
          hasApiKey: false,
        ),
        isFalse,
      );
    });

    test('no fallback when not on OAuth', () {
      expect(
        shouldFallBackToApiKey(
          kind: ClaudeErrorKind.auth,
          oauthActive: false,
          alreadyFellBack: false,
          hasApiKey: true,
        ),
        isFalse,
      );
    });

    test('no fallback for non-auth kinds', () {
      for (final kind in [
        ClaudeErrorKind.billing,
        ClaudeErrorKind.transient,
        ClaudeErrorKind.other,
      ]) {
        expect(
          shouldFallBackToApiKey(
            kind: kind,
            oauthActive: true,
            alreadyFellBack: false,
            hasApiKey: true,
          ),
          isFalse,
          reason: '$kind should not trigger fallback',
        );
      }
    });
  });

  group('extractHttpCode', () {
    test('reads code from a duck-typed exception', () {
      final err = _FakeAnthropicException(code: 429, body: 'x');
      expect(extractHttpCode(err), 429);
    });

    test('returns null when no code getter exists', () {
      expect(extractHttpCode(Exception('plain')), isNull);
      expect(extractHttpCode(StateError('plain')), isNull);
    });
  });

  group('claudeErrorUserMessage', () {
    test('every kind yields a non-empty, distinct message', () {
      final messages = {
        for (final k in ClaudeErrorKind.values) k: claudeErrorUserMessage(k),
      };
      // None blank — the whole point is the user is never left with a dead
      // "something went wrong".
      for (final entry in messages.entries) {
        expect(entry.value.trim(), isNotEmpty, reason: '${entry.key} message');
      }
      // Each kind reads differently — the classification actually reaches the
      // user rather than collapsing to one generic line.
      expect(messages.values.toSet(), hasLength(ClaudeErrorKind.values.length));
    });

    test('each message names what actually broke', () {
      expect(claudeErrorUserMessage(ClaudeErrorKind.billing).toLowerCase(),
          contains('credit'));
      expect(
          claudeErrorUserMessage(ClaudeErrorKind.transient), contains('429'));
      expect(
        claudeErrorUserMessage(ClaudeErrorKind.auth).toLowerCase(),
        anyOf(contains('login'), contains('credential'), contains('auth')),
      );
      // `other` has no specific cause, but must still say *something* concrete
      // rather than a blank — guard it so the group name doesn't overclaim.
      expect(claudeErrorUserMessage(ClaudeErrorKind.other).toLowerCase(),
          anyOf(contains('misfired'), contains('nick')));
    });
  });

  group('redactSecrets', () {
    test('keeps ordinary error text untouched', () {
      expect(redactSecrets('rate limit hit (429)'), 'rate limit hit (429)');
      expect(redactSecrets('connection reset by peer'),
          'connection reset by peer');
    });

    test('masks provider-prefixed tokens and URL credentials', () {
      expect(redactSecrets('bad key sk-ant-abc12345defg'),
          isNot(contains('sk-ant-abc12345defg')));
      expect(
        redactSecrets('connect https://user:hunter2@radicale.example/dav'),
        isNot(contains('hunter2')),
      );
      expect(redactSecrets('token=${'a' * 40}'), contains('<redacted'));
    });

    // The canonical HTTP auth form leaked before: the label rule consumed only
    // up to "Bearer" and left the credential. Use a NON-prefixed token so the
    // provider-prefix rule can't mask the bug (the old test passed by accident
    // because its token started `xoxb-`).
    test('masks a non-prefixed Authorization: Bearer token', () {
      final r = redactSecrets(
          'HTTP 401 Authorization: Bearer abcDEF123456ghIJklMNop0987 denied');
      expect(r, isNot(contains('abcDEF123456ghIJklMNop0987')));
      expect(r, contains('<redacted'));
    });

    test('masks a bare Bearer token with no header label', () {
      final r = redactSecrets('sending Bearer notaknownprefix_9times8');
      expect(r, isNot(contains('notaknownprefix_9times8')));
    });

    test('masks a JWT (dotted blob starting eyJ)', () {
      const jwt = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.'
          'dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U';
      final r = redactSecrets('unauthorized: $jwt (bad sig)');
      expect(r, isNot(contains(jwt)));
      expect(r, contains('<redacted-jwt>'));
    });

    test('masks non-Bearer Authorization schemes (Basic/Token)', () {
      final basic = redactSecrets(
          'HTTP 401 Authorization: Basic dXNlcjpwYXNzd29yZA denied');
      expect(basic, isNot(contains('dXNlcjpwYXNzd29yZA')));
      final tok = redactSecrets('Authorization: Token deadbeefsecretvalue99');
      expect(tok, isNot(contains('deadbeefsecretvalue99')));
    });

    test('masks Digest auth credential params (response/nonce)', () {
      final r = redactSecrets(
          'Authorization: Digest username="nick", realm="x", '
          'nonce="deadbeefnonce", uri="/", response="abcdef0123456789hash"');
      // The actual credential material (response hash + nonce) must be masked;
      // non-secret params (username/realm/uri) may remain.
      expect(r, isNot(contains('abcdef0123456789hash')));
      expect(r, isNot(contains('deadbeefnonce')));
    });

    test('masks a quoted JSON secret value with internal delimiters', () {
      // The value has commas/semicolons/equals inside the quotes — the tail
      // must not leak (cage-match r2: unquoted-only capture stopped at the
      // first comma and leaked the rest).
      final r =
          redactSecrets('Error: {"client_secret": "foo,bar;baz=qux", "ok": 1}');
      expect(r, isNot(contains('bar')));
      expect(r, isNot(contains('baz')));
      expect(r, isNot(contains('qux')));
      expect(r, contains('<redacted'));
    });

    test('masks additional secret formats (AWS, ghs_, client_secret)', () {
      expect(redactSecrets('id AKIAIOSFODNN7EXAMPLE here'),
          isNot(contains('AKIAIOSFODNN7EXAMPLE')));
      expect(redactSecrets('bad ghs_16CharsOrMoreToken12345xyz'),
          isNot(contains('ghs_16CharsOrMoreToken12345xyz')));
      expect(redactSecrets('client_secret=abcdef123456supersecretxyz'),
          isNot(contains('abcdef123456supersecretxyz')));
    });

    test('roomSafeErrorDetail redacts BEFORE truncating (secret past the cut)',
        () {
      // A secret that starts past the 200-char boundary. Truncate-first would
      // slice it into a fragment that evades the patterns; redact-first masks it
      // on the full string before the cut.
      const secret = 'Bearer verylongsecrettoken0123456789abcdefGHIJ';
      final padded = '${'x' * 190} $secret trailing';
      final r = roomSafeErrorDetail(Exception(padded));
      expect(r, isNot(contains('verylongsecrettoken0123456789abcdefGHIJ')));
    });

    test('roomSafeErrorDetail truncates the safe string to maxLength', () {
      final r = roomSafeErrorDetail(Exception('y' * 500));
      expect(r.length, lessThanOrEqualTo(201)); // 200 + the ellipsis char
    });
  });
}
