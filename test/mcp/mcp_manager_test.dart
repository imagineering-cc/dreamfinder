import 'package:dreamfinder/src/agent/tool_registry.dart';
import 'package:dreamfinder/src/mcp/mcp_manager.dart';
import 'package:test/test.dart';

void main() {
  late McpManager manager;
  setUp(() {
    manager = McpManager();
  });

  group('McpManager', () {
    test('getAllTools merges tools from all servers', () {
      manager.addServerForTesting(
          'kan',
          McpToolInfo(name: 'kan_list_boards', description: 'List boards'),
          McpToolInfo(name: 'kan_create_card', description: 'Create card'));
      manager.addServerForTesting('outline',
          McpToolInfo(name: 'outline_search', description: 'Search docs'));
      final tools = manager.getAllTools();
      expect(tools, hasLength(3));
      expect(
          tools.map((t) => t.name),
          containsAll(<String>[
            'kan_list_boards',
            'kan_create_card',
            'outline_search'
          ]));
    });

    test('callTool routes to correct server', () async {
      manager.addServerForTesting(
          'kan',
          McpToolInfo(
              name: 'kan_search',
              description: 'Search',
              handler: (a) async => '{"results": ["task-1"]}'));
      manager.addServerForTesting(
          'outline',
          McpToolInfo(
              name: 'outline_search',
              description: 'Search',
              handler: (a) async => '{"results": ["doc-1"]}'));
      expect(await manager.callTool('kan_search', <String, dynamic>{}),
          contains('task-1'));
      expect(await manager.callTool('outline_search', <String, dynamic>{}),
          contains('doc-1'));
    });

    test('callTool throws for unknown tool', () {
      manager.addServerForTesting(
          'kan', McpToolInfo(name: 'kan_search', description: 'Search'));
      expect(() => manager.callTool('nonexistent', <String, dynamic>{}),
          throwsA(isA<Exception>()));
    });

    test('getServerNames returns all servers', () {
      manager.addServerForTesting(
          'kan', McpToolInfo(name: 'k', description: 's'));
      manager.addServerForTesting(
          'outline', McpToolInfo(name: 'o', description: 's'));
      expect(manager.getServerNames(), containsAll(<String>['kan', 'outline']));
    });
  });

  group('ToolRegistry + McpManager', () {
    test('merges MCP and custom tools', () {
      final reg = ToolRegistry();
      reg.registerCustomTool(CustomToolDef(
        name: 'sprint_info',
        description: 'Sprint info',
        inputSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{}
        },
        handler: (a) async => 'Sprint 5',
      ));
      manager.addServerForTesting(
          'kan', McpToolInfo(name: 'kan_search', description: 'Search'));
      reg.setMcpManager(manager);
      final tools = reg.getAllToolDefinitions();
      expect(tools, hasLength(2));
      expect(tools.map((t) => t.name),
          containsAll(<String>['sprint_info', 'kan_search']));
    });

    test('executeTool routes custom tools first', () async {
      final reg = ToolRegistry();
      reg.registerCustomTool(CustomToolDef(
        name: 'my_tool',
        description: 'Custom',
        inputSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{}
        },
        handler: (a) async => 'custom result',
      ));
      expect(await reg.executeTool('my_tool', <String, dynamic>{}),
          equals('custom result'));
    });
  });
}
