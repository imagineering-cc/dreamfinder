/// CLI tool to obtain a Claude Max OAuth refresh token for Dreamfinder.
///
/// Extracts the refresh token from a local Claude Code session (macOS Keychain),
/// exchanges it for a new token pair, and prints the refresh token for deployment.
///
/// Prerequisites:
///   - Claude Code must be installed and logged in (`claude` CLI)
///   - macOS only (uses `security` command for Keychain access)
///
/// Usage: dart run tool/get_refresh_token.dart
///
/// After running, Claude Code's token will be invalidated — run `/login` in
/// Claude Code to re-authenticate.
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

const _clientId = '9d1c250a-e61b-44d9-88ed-5944d1962f5e'; // Claude Code CLI
const _tokenUrl = 'https://api.anthropic.com/v1/oauth/token';

void main() async {
  // Step 1: Extract refresh token from macOS Keychain.
  print('Extracting Claude Code credentials from macOS Keychain...');
  final result = await Process.run(
    'security',
    ['find-generic-password', '-s', 'Claude Code-credentials', '-w'],
  );

  if (result.exitCode != 0) {
    print('Error: Could not find Claude Code credentials in Keychain.');
    print('Make sure Claude Code is installed and you are logged in.');
    print('Run `claude` and authenticate first, then retry.');
    exit(1);
  }

  final credsJson = (result.stdout as String).trim();
  final creds = jsonDecode(credsJson) as Map<String, dynamic>;
  final oauth = creds['claudeAiOauth'] as Map<String, dynamic>?;

  if (oauth == null) {
    print('Error: No OAuth credentials found in Claude Code keychain entry.');
    print('You may be using API key auth. Switch to OAuth login first.');
    exit(1);
  }

  final sourceRefreshToken = oauth['refreshToken'] as String?;
  if (sourceRefreshToken == null || sourceRefreshToken.isEmpty) {
    print('Error: No refresh token in Claude Code credentials.');
    exit(1);
  }

  final scopes = (oauth['scopes'] as List?)?.join(', ') ?? 'unknown';
  final subType = oauth['subscriptionType'] ?? 'unknown';
  print('Found credentials (subscription: $subType, scopes: $scopes)');
  print('');

  // Step 2: Exchange for a new token pair.
  print('Exchanging refresh token for a new Dreamfinder token pair...');
  print('(This will invalidate Claude Code\'s current session)');
  print('');

  final response = await http.post(
    Uri.parse(_tokenUrl),
    headers: {'Content-Type': 'application/x-www-form-urlencoded'},
    body: {
      'grant_type': 'refresh_token',
      'refresh_token': sourceRefreshToken,
      'client_id': _clientId,
    },
  );

  if (response.statusCode != 200) {
    print('Token exchange failed (${response.statusCode}):');
    print(response.body);
    print('');
    print('If the token was already used, run /login in Claude Code and retry.');
    exit(1);
  }

  final data = jsonDecode(response.body) as Map<String, dynamic>;
  final refreshToken = data['refresh_token'] as String?;
  final accessToken = data['access_token'] as String?;
  final expiresIn = data['expires_in'] as int?;

  if (refreshToken == null) {
    print('No refresh token in response:');
    print(response.body);
    exit(1);
  }

  print('=== SUCCESS ===');
  print('');
  print('Access token: ${accessToken?.substring(0, 30)}...');
  print(
    'Expires in: '
    '${expiresIn != null ? "${(expiresIn / 3600).round()}h" : "unknown"}',
  );
  print('');
  print('CLAUDE_REFRESH_TOKEN=$refreshToken');
  print('');
  print('Add this to your deployment .env file.');
  print('The token is single-use — after first refresh, the bot persists');
  print('new tokens to SQLite automatically.');
  print('');
  print('IMPORTANT: Run /login in Claude Code now to re-authenticate.');
}
