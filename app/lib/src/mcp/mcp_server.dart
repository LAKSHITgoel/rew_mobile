// Serves MCP over HTTP so a model on your laptop can reach the phone.
//
// This opens a port on the local network, and one of the tools plays sound
// through the car. So it is off unless switched on, it requires a token that
// only appears on the phone's screen, and it binds to the local network rather
// than anything routable from outside it.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'mcp_protocol.dart';
import 'mcp_tools.dart';

class McpServer extends ChangeNotifier {
  McpServer({required this.tools, this.port = 8787});

  final List<McpTool> tools;
  final int port;

  HttpServer? _server;
  String? _token;
  String? _address;
  String? error;

  bool get running => _server != null;
  String? get token => _token;

  /// What to paste into an MCP client, once running.
  String? get url => _address == null ? null : 'http://$_address:$port/mcp';

  Future<void> start() async {
    if (running) return;
    error = null;
    try {
      // A fresh token each time it is switched on: a token that outlives the
      // session it was shown in is a password nobody remembers sharing.
      _token = _makeToken();
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      _address = await _localAddress();
      unawaited(_serve(_server!));
    } catch (e) {
      error = '$e';
      _server = null;
      _token = null;
    }
    notifyListeners();
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    _token = null;
    _address = null;
    await s?.close(force: true);
    notifyListeners();
  }

  Future<void> _serve(HttpServer server) async {
    // One session per server: this is a single-user instrument on a phone, not
    // a multi-tenant service.
    final session = McpSession(tools: tools);

    await for (final req in server) {
      try {
        if (req.method == 'OPTIONS') {
          _cors(req.response);
          req.response.statusCode = HttpStatus.ok;
          await req.response.close();
          continue;
        }

        if (!_authorised(req)) {
          _cors(req.response);
          req.response.statusCode = HttpStatus.unauthorized;
          req.response.write(jsonEncode({
            'error': 'Send the token from the app as: Authorization: Bearer <token>'
          }));
          await req.response.close();
          continue;
        }

        if (req.method != 'POST') {
          _cors(req.response);
          req.response.statusCode = HttpStatus.methodNotAllowed;
          await req.response.close();
          continue;
        }

        final body = await utf8.decoder.bind(req).join();
        final decoded = jsonDecode(body);

        // A batch is a JSON array; a single call is an object. Both are legal.
        Object? reply;
        if (decoded is List) {
          final replies = <Map<String, dynamic>>[];
          for (final m in decoded) {
            final r = await session.handle((m as Map).cast<String, dynamic>());
            if (r != null) replies.add(r);
          }
          reply = replies.isEmpty ? null : replies;
        } else {
          reply = await session.handle((decoded as Map).cast<String, dynamic>());
        }

        _cors(req.response);
        if (reply == null) {
          // Notifications get no body, only an acknowledgement.
          req.response.statusCode = HttpStatus.accepted;
        } else {
          req.response.statusCode = HttpStatus.ok;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode(reply));
        }
        await req.response.close();
      } catch (e) {
        try {
          req.response.statusCode = HttpStatus.internalServerError;
          req.response.write(jsonEncode({'error': '$e'}));
          await req.response.close();
        } catch (_) {
          // The client hung up mid-reply; nothing useful left to do.
        }
      }
    }
  }

  bool _authorised(HttpRequest req) {
    final expected = _token;
    if (expected == null) return false;
    final header = req.headers.value(HttpHeaders.authorizationHeader) ?? '';
    final offered = header.startsWith('Bearer ') ? header.substring(7) : '';
    if (offered.length != expected.length) return false;
    // Constant time over the whole string: comparing with == would leak the
    // token a character at a time to anything that can time the replies.
    var diff = 0;
    for (var i = 0; i < expected.length; i++) {
      diff |= expected.codeUnitAt(i) ^ offered.codeUnitAt(i);
    }
    return diff == 0;
  }

  void _cors(HttpResponse res) {
    res.headers.set('Access-Control-Allow-Origin', '*');
    res.headers.set('Access-Control-Allow-Headers', 'Authorization, Content-Type');
    res.headers.set('Access-Control-Allow-Methods', 'POST, OPTIONS');
  }

  static String _makeToken() {
    final rnd = Random.secure();
    const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(24, (_) => alphabet[rnd.nextInt(alphabet.length)])
        .join();
  }

  /// The phone's address on the local network, so the URL shown can actually
  /// be typed into a laptop.
  static Future<String?> _localAddress() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final i in interfaces) {
        for (final a in i.addresses) {
          if (!a.isLoopback) return a.address;
        }
      }
    } catch (_) {
      // No network, or the platform will not enumerate; the UI says so.
    }
    return null;
  }

  @override
  void dispose() {
    unawaited(stop());
    super.dispose();
  }
}
