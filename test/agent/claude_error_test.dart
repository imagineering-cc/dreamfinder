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
    test('masks tokens/keys/auth but keeps ordinary error text', () {
      expect(redactSecrets('rate limit hit (429)'), 'rate limit hit (429)');
      expect(redactSecrets('bad key sk-ant-abc12345defg'),
          isNot(contains('sk-ant-abc12345defg')));
      expect(redactSecrets('Authorization: Bearer xoxb-9999-deadbeefcafe'),
          isNot(contains('deadbeefcafe')));
      expect(
        redactSecrets('connect https://user:hunter2@radicale.example/dav'),
        isNot(contains('hunter2')),
      );
      // A long opaque blob is masked.
      expect(redactSecrets('token=${'a' * 40}'), contains('<redacted'));
    });
  });
}
