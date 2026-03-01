import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:dart_mcp/client.dart';
import 'package:dart_mcp/stdio.dart';
import 'package:meta/meta.dart';

/// Metadata for a single MCP tool.
class McpToolInfo {
  McpToolInfo({
    required this.name,
    required this.description,
    this.inputSchema = const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
    },
    this.handler,
  });

  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;

  /// Optional handler for testing. Production calls go via MCP protocol.
  final Future<String> Function(Map<String, dynamic> args)? handler;
}

/// Configuration for spawning an MCP server subprocess.
class McpServerConfig {
  const McpServerConfig({
    required this.name,
    required this.command,
    required this.args,
    this.env = const <String, String>{},
  });

  final String name;
  final String command;
  final List<String> args;
  final Map<String, String> env;
}

/// A running MCP server with its connection, tools, and process.
class _ManagedServer {
  _ManagedServer({
    required this.name,
    required this.tools,
    this.process,
    this.connection,
  });

  final String name;
  final List<McpToolInfo> tools;
  final Process? process;
  final ServerConnection? connection;
}

/// Manages MCP server subprocesses and routes tool calls.
///
/// In production, connects to each subprocess via dart_mcp's STDIO transport,
/// discovers tools via `listTools()`, and routes `callTool()` through the
/// MCP JSON-RPC protocol.
class McpManager {
  final Map<String, _ManagedServer> _servers = {};
  MCPClient? _mcpClient;

  /// Returns all tools across all connected MCP servers.
  List<McpToolInfo> getAllTools() {
    return <McpToolInfo>[
      for (final server in _servers.values) ...server.tools,
    ];
  }

  /// Calls a tool by name, routing to the correct MCP server.
  Future<String> callTool(
    String toolName,
    Map<String, dynamic> args,
  ) async {
    for (final server in _servers.values) {
      for (final tool in server.tools) {
        if (tool.name == toolName) {
          // Testing path: use injected handler.
          if (tool.handler != null) return tool.handler!(args);

          // Production path: call via MCP protocol.
          final conn = server.connection;
          if (conn == null || !conn.isActive) {
            throw StateError(
              'MCP server ${server.name} is not connected',
            );
          }

          final result = await conn.callTool(
            CallToolRequest(
              name: toolName,
              arguments: args.cast<String, Object?>(),
            ),
          );

          if (result.isError == true) {
            final errorText = result.content
                .where((c) => c.isText)
                .map((c) => (c as TextContent).text)
                .join('\n');
            throw Exception(
              'MCP tool $toolName failed: $errorText',
            );
          }

          // Extract text content from result blocks.
          return result.content
              .where((c) => c.isText)
              .map((c) => (c as TextContent).text)
              .join('\n');
        }
      }
    }

    throw Exception('MCP tool not found: $toolName');
  }

  /// Returns the names of all registered MCP servers.
  List<String> getServerNames() => _servers.keys.toList();

  /// Shuts down all MCP server subprocesses.
  Future<void> shutdown() async {
    if (_mcpClient != null) {
      await _mcpClient!.shutdown();
      _mcpClient = null;
    }
    for (final entry in _servers.entries) {
      entry.value.process?.kill();
      developer.log('Shut down ${entry.key}', name: 'McpManager');
    }
    _servers.clear();
  }

  /// Injects a test server with the given tools. No subprocess is spawned.
  @visibleForTesting
  void addServerForTesting(String name, McpToolInfo tool,
      [McpToolInfo? tool2, McpToolInfo? tool3]) {
    final tools = <McpToolInfo>[
      tool,
      if (tool2 != null) tool2,
      if (tool3 != null) tool3,
    ];
    _servers[name] = _ManagedServer(name: name, tools: tools);
  }

  /// Starts an MCP server subprocess, connects via STDIO, and discovers tools.
  Future<void> startServer(McpServerConfig config) async {
    try {
      developer.log(
        'Starting ${config.name}: ${config.command} ${config.args.join(" ")}',
        name: 'McpManager',
      );

      final process = await Process.start(
        config.command,
        config.args,
        environment: <String, String>{
          ...Platform.environment,
          ...config.env,
        },
      );

      // Log stderr from the MCP server for debugging.
      process.stderr.transform(const SystemEncoding().decoder).listen((line) {
        developer.log(
          '${config.name} stderr: $line',
          name: 'McpManager',
        );
      });

      // Create MCP client (shared across all servers).
      _mcpClient ??= MCPClient(
        Implementation(name: 'dreamfinder', version: '0.1.0'),
      );

      // Connect via STDIO channel.
      final channel = stdioChannel(
        input: process.stdout,
        output: process.stdin,
      );
      final connection = _mcpClient!.connectServer(channel);

      // Kill process if connection drops.
      unawaited(connection.done.then((_) {
        if (_servers.containsKey(config.name)) {
          developer.log(
            '${config.name} connection closed unexpectedly',
            name: 'McpManager',
            level: 900,
          );
          process.kill();
        }
      }));

      // Initialize MCP handshake.
      final initResult = await connection.initialize(
        InitializeRequest(
          protocolVersion: ProtocolVersion.latestSupported,
          capabilities: _mcpClient!.capabilities,
          clientInfo: _mcpClient!.implementation,
        ),
      );
      connection.notifyInitialized();

      developer.log(
        '${config.name} initialized: ${initResult.serverInfo.name}',
        name: 'McpManager',
      );

      // Discover tools.
      final tools = <McpToolInfo>[];
      if (initResult.capabilities.tools != null) {
        final toolsResult = await connection.listTools();
        for (final tool in toolsResult.tools) {
          tools.add(McpToolInfo(
            name: tool.name,
            description: tool.description ?? '',
            inputSchema: (tool.inputSchema as Map<String, dynamic>?) ??
                const <String, dynamic>{
                  'type': 'object',
                  'properties': <String, dynamic>{},
                },
          ));
        }
      }

      _servers[config.name] = _ManagedServer(
        name: config.name,
        tools: tools,
        process: process,
        connection: connection,
      );

      developer.log(
        '${config.name} ready with ${tools.length} tools',
        name: 'McpManager',
      );
    } on Exception catch (e) {
      developer.log(
        'Failed to start ${config.name}: $e',
        name: 'McpManager',
        level: 1000,
      );
    }
  }
}
