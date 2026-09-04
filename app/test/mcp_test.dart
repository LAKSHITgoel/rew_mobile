// The MCP surface: the handshake, the tools, and the token that guards them.
// Tested through maps and a real socket rather than mocked away, because the
// two things most likely to be wrong here are the protocol shape a client
// expects and whether the door is actually locked.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rew_mobile/src/mcp/mcp_protocol.dart';
import 'package:rew_mobile/src/mcp/mcp_server.dart';
import 'package:rew_mobile/src/mcp/mcp_tools.dart';
import 'package:rew_mobile/src/models/measurement.dart';
import 'package:rew_mobile/src/models/project.dart';

class _FakeContext implements McpContext {
  _FakeContext();

  int measureCalls = 0;

  final TuneProject tune = TuneProject(
    id: 'nexon',
    name: 'Nexon',
    createdAt: DateTime(2026, 9, 4),
  )
    ..measured['system'] = FreqResponse(
      List<double>.generate(200, (i) => 20.0 * (i + 1)),
      List<double>.generate(200, (i) => -40.0 + (i % 7)),
    )
    ..noiseFloors['system'] = FreqResponse(
      List<double>.generate(200, (i) => 20.0 * (i + 1)),
      List<double>.filled(200, -80),
    )
    ..levelsDbfs['system'] = -14.8
    ..eqBands['system'] = [
      const PeqBand(
        freqHz: 51,
        gainDb: -6,
        q: 3,
        reason: PeqReason.broadExcess,
        confidence: 0.9,
      ),
    ];

  @override
  Future<List<TuneProject>> listTunes() async => [tune];

  @override
  Future<TuneProject?> getTune(String id) async => id == tune.id ? tune : null;

  @override
  Future<Measurement> measure({String? tuneId, int positions = 3}) async {
    measureCalls++;
    return Measurement(
      response: tune.measured['system']!,
      levelDbfs: -14.8,
      noiseFloor: FreqResponse(
        tune.measured['system']!.freqHz,
        List<double>.filled(200, -80),
      ),
    );
  }

  @override
  FreqResponse? rtaSpectrum() => null;

  @override
  double? rtaLevelDbfs() => null;
}

Map<String, dynamic> _req(int id, String method, [Map<String, dynamic>? params]) =>
    {'jsonrpc': '2.0', 'id': id, 'method': method, if (params != null) 'params': params};

void main() {
  late _FakeContext ctx;
  late McpSession session;

  setUp(() {
    ctx = _FakeContext();
    session = McpSession(tools: buildTools(ctx));
  });

  test('initialize returns a protocol version and declares tools', () async {
    final r = await session.handle(_req(1, 'initialize'));
    expect(r!['result']['protocolVersion'], kMcpProtocolVersion);
    expect(r['result']['capabilities']['tools'], isNotNull);
    // The instructions are what steer a model toward reviewing rather than
    // driving, so their absence is a real regression.
    expect(r['result']['instructions'], contains('second opinion'));
  });

  test('notifications are not answered', () async {
    expect(await session.handle({'jsonrpc': '2.0', 'method': 'notifications/initialized'}),
        isNull);
  });

  test('tools/list describes every tool with a schema', () async {
    final r = await session.handle(_req(2, 'tools/list'));
    final tools = (r!['result']['tools'] as List).cast<Map<String, dynamic>>();
    expect(tools.map((t) => t['name']),
        containsAll(['list_tunes', 'get_measurement', 'get_recommendations',
          'measure', 'get_rta']));
    for (final t in tools) {
      expect(t['description'], isNotEmpty);
      expect(t['inputSchema']['type'], 'object');
    }
  });

  Future<Map<String, dynamic>> callTool(String name,
      [Map<String, dynamic> args = const {}]) async {
    final r = await session
        .handle(_req(9, 'tools/call', {'name': name, 'arguments': args}));
    final text = r!['result']['content'][0]['text'] as String;
    return jsonDecode(text) as Map<String, dynamic>;
  }

  test('list_tunes reports the saved tunes', () async {
    final out = await callTool('list_tunes');
    expect((out['tunes'] as List).single['name'], 'Nexon');
  });

  test('a measurement comes back with its noise floor', () async {
    final out = await callTool('get_measurement', {'tuneId': 'nexon'});
    expect(out['channel'], 'system');
    expect((out['points'] as List), isNotEmpty);
    // Curves are thinned: a model does not need 200 points to form a view.
    expect((out['points'] as List).length, lessThanOrEqualTo(96));
    // The noise floor must come back with the curve: without it a reviewer
    // cannot tell which part of the measurement is the car.
    expect(out['noiseFloor'], isNotEmpty);
    expect(out['usableTo'], isNotNull);
    expect(out['note'], contains('noise'));
  });

  test('recommendations carry their reasons and confidence', () async {
    final out = await callTool('get_recommendations', {'tuneId': 'nexon'});
    final band = (out['bands'] as List).single as Map<String, dynamic>;
    expect(band['hz'], 51);
    expect(band['reason'], isNotEmpty);
    expect(band['why'], isNotEmpty);
    expect(band['confidence'], 0.9);
    // The principles tell a reviewer what the app was trying to do, so it can
    // disagree with the reasoning rather than just the numbers.
    expect(out['principles'], contains('boost'));
  });

  test('asking for a tune that does not exist is an answer, not a crash',
      () async {
    final out = await callTool('get_measurement', {'tuneId': 'nope'});
    expect(out['error'], isNotNull);
  });

  test('measure actually runs a measurement', () async {
    final out = await callTool('measure', {'tuneId': 'nexon', 'positions': 2});
    expect(ctx.measureCalls, 1);
    expect(out['points'], isNotEmpty);
    expect(out['noiseFloor'], isNotEmpty);
  });

  test('an unknown tool is refused', () async {
    final r = await session
        .handle(_req(3, 'tools/call', {'name': 'rm_rf', 'arguments': {}}));
    expect(r!['error']['code'], -32602);
  });

  group('over HTTP', () {
    late McpServer server;

    setUp(() async {
      server = McpServer(tools: buildTools(ctx), port: 8791);
      await server.start();
    });

    tearDown(() async => server.stop());

    Future<HttpClientResponse> post(String body, {String? token}) async {
      final client = HttpClient();
      final req = await client.post('127.0.0.1', 8791, '/mcp');
      if (token != null) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      req.headers.contentType = ContentType.json;
      req.write(body);
      return req.close();
    }

    test('serves a real client that presents the token', () async {
      expect(server.running, isTrue);
      expect(server.token, isNotNull);

      final res =
          await post(jsonEncode(_req(1, 'initialize')), token: server.token);
      expect(res.statusCode, HttpStatus.ok);
      final body = jsonDecode(await utf8.decoder.bind(res).join());
      expect(body['result']['serverInfo']['name'], 'rew_mobile');
    });

    test('refuses a client with no token, or the wrong one', () async {
      expect((await post(jsonEncode(_req(1, 'initialize')))).statusCode,
          HttpStatus.unauthorized);
      expect(
          (await post(jsonEncode(_req(1, 'initialize')), token: 'wrong'))
              .statusCode,
          HttpStatus.unauthorized);
    });

    test('a new token is issued each time it is switched on', () async {
      final first = server.token;
      await server.stop();
      expect(server.running, isFalse);
      expect(server.token, isNull);
      await server.start();
      expect(server.token, isNot(first));
    });
  });
}
