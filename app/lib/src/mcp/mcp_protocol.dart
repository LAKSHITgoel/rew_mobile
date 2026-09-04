// MCP's JSON-RPC layer, with no sockets in it.
//
// Separated from the HTTP server so the whole protocol — handshake, tool
// listing, dispatch, error shapes — can be tested by passing maps in and
// reading maps out, which is far more useful than testing it through a socket.
import 'dart:async';
import 'dart:convert';

import 'mcp_tools.dart';

/// The revision of MCP this speaks.
const String kMcpProtocolVersion = '2024-11-05';

class McpSession {
  McpSession({required this.tools, this.serverName = 'rew_mobile'});

  final List<McpTool> tools;
  final String serverName;

  bool _initialised = false;
  bool get initialised => _initialised;

  /// Handles one JSON-RPC message. Returns the reply, or null for
  /// notifications, which by definition are not answered.
  Future<Map<String, dynamic>?> handle(Map<String, dynamic> msg) async {
    final method = msg['method'] as String?;
    final id = msg['id'];
    final isNotification = id == null;

    if (method == null) {
      return isNotification ? null : _error(id, -32600, 'missing method');
    }

    switch (method) {
      case 'initialize':
        _initialised = true;
        return _ok(id, {
          'protocolVersion': kMcpProtocolVersion,
          'capabilities': {
            'tools': {'listChanged': false},
          },
          'serverInfo': {'name': serverName, 'version': '0.1.0'},
          'instructions':
              'This is a car-audio measurement app acting as an instrument. '
              'You are here to review measurements and give a second opinion, '
              'not to drive the tune: the app computes its own recommendations '
              'with explicit reasons and confidence scores. Say where you '
              'agree, where you would do something different, and why. Note '
              'that anything the sweep did not lift clear of the noise floor '
              'is not a measurement of the car.',
        });

      case 'notifications/initialized':
        return null;

      case 'ping':
        return _ok(id, const {});

      case 'tools/list':
        return _ok(id, {'tools': [for (final t in tools) t.toJson()]});

      case 'tools/call':
        final params = (msg['params'] as Map?)?.cast<String, dynamic>() ?? {};
        final name = params['name'] as String?;
        final args =
            (params['arguments'] as Map?)?.cast<String, dynamic>() ?? {};
        final tool = tools.where((t) => t.name == name).firstOrNull;
        if (tool == null) {
          return _error(id, -32602, 'no such tool: $name');
        }
        try {
          final result = await tool.handler(args);
          return _ok(id, {
            'content': [
              {
                'type': 'text',
                'text': const JsonEncoder.withIndent('  ').convert(result),
              }
            ],
            'isError': false,
          });
        } catch (e) {
          // A failing tool is reported through the result, not as a transport
          // error: the model should see what went wrong and be able to react,
          // rather than the call simply vanishing.
          return _ok(id, {
            'content': [
              {'type': 'text', 'text': 'Tool failed: $e'}
            ],
            'isError': true,
          });
        }

      default:
        return isNotification ? null : _error(id, -32601, 'unknown method: $method');
    }
  }

  Map<String, dynamic> _ok(Object? id, Map<String, dynamic> result) =>
      {'jsonrpc': '2.0', 'id': id, 'result': result};

  Map<String, dynamic> _error(Object? id, int code, String message) =>
      {'jsonrpc': '2.0', 'id': id, 'error': {'code': code, 'message': message}};
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
