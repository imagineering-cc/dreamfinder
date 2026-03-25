/// Config-driven MCP server loading.
///
/// Reads MCP server definitions from a JSON config file, resolving
/// environment variable references (`$VAR` or `${VAR}`) in env values.
/// This allows extensions to be added without modifying Dart code —
/// just add an entry to `mcp-config.json` and restart.
library;

import 'dart:convert';
import 'dart:io';

import 'mcp_manager.dart';

/// Default config file path, relative to the working directory.
const defaultMcpConfigPath = 'mcp-config.json';

/// Loads MCP server configurations from a JSON file.
///
/// The file should contain a JSON array of server objects:
/// ```json
/// [
///   {
///     "name": "kan",
///     "command": "node",
///     "args": ["mcp-servers/packages/kan/index.js"],
///     "env": {
///       "KAN_BASE_URL": "$KAN_BASE_URL",
///       "KAN_API_KEY": "$KAN_API_KEY"
///     },
///     "enabled": true
///   }
/// ]
/// ```
///
/// Environment variable references in `env` values are resolved against
/// the current process environment. If a referenced variable is unset,
/// the server is skipped (logged as disabled).
///
/// Returns an empty list if the file doesn't exist or can't be parsed.
List<McpServerConfig> loadMcpConfig([String path = defaultMcpConfigPath]) {
  final file = File(path);
  if (!file.existsSync()) return [];

  final content = file.readAsStringSync();
  final list = jsonDecode(content) as List;

  final configs = <McpServerConfig>[];
  for (final entry in list) {
    final map = entry as Map<String, dynamic>;
    final config = _parseServerEntry(map);
    if (config != null) configs.add(config);
  }

  return configs;
}

/// Parses a single server entry from the config file.
///
/// Returns `null` if the server is disabled or has unresolved required env vars.
McpServerConfig? _parseServerEntry(Map<String, dynamic> map) {
  final name = map['name'] as String;
  final enabled = map['enabled'] as bool? ?? true;
  if (!enabled) return null;

  final command = map['command'] as String;
  final args = (map['args'] as List).cast<String>();

  // Resolve environment variable references in env values.
  final rawEnv = (map['env'] as Map<String, dynamic>?) ?? {};
  final resolvedEnv = <String, String>{};
  for (final entry in rawEnv.entries) {
    final value = entry.value as String;
    final resolved = _resolveEnvVar(value);
    if (resolved == null || resolved.isEmpty) {
      // Required env var is unset — skip this server entirely.
      return null;
    }
    resolvedEnv[entry.key] = resolved;
  }

  return McpServerConfig(
    name: name,
    command: command,
    args: args,
    env: resolvedEnv,
  );
}

/// Resolves `$VAR` or `${VAR}` references in a string against the process
/// environment. Returns `null` if a referenced variable is unset.
///
/// Literal strings (no `$`) are returned as-is.
String? _resolveEnvVar(String value) {
  // Match $VAR or ${VAR} patterns.
  final pattern = RegExp(r'\$\{(\w+)\}|\$(\w+)');

  if (!pattern.hasMatch(value)) return value;

  var result = value;
  for (final match in pattern.allMatches(value)) {
    final varName = match.group(1) ?? match.group(2)!;
    final envValue = Platform.environment[varName];
    if (envValue == null || envValue.isEmpty) return null;
    result = result.replaceFirst(match.group(0)!, envValue);
  }

  return result;
}
