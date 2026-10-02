import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conclave_workspace/workspace_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('HTTP long-poll carries common protocol messages and opaque cursors',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final postedEvents = Completer<Map<String, dynamic>>();
    var closed = false;
    var delivered = false;
    final serving = () async {
      await for (final request in server) {
        final body = await utf8.decoder.bind(request).join();
        final decoded = body.isEmpty
            ? <String, dynamic>{}
            : jsonDecode(body) as Map<String, dynamic>;
        request.response.headers.contentType = ContentType.json;
        switch (request.uri.path) {
          case '/api/workspace-runtime/sessions':
            request.response.write(jsonEncode({
              'sessionId': 'session-1',
              'serverTime': DateTime.now().toUtc().toIso8601String(),
              'pollTimeoutMs': 25000,
              'heartbeatIntervalMs': 15000,
              'cursor': 'opaque-cursor-1',
            }));
          case '/api/workspace-runtime/events':
            postedEvents.complete(decoded);
            request.response.write(jsonEncode({
              'acceptedEventIds': ['event-1'],
              'rejected': [],
              'cursor': 'opaque-cursor-2',
            }));
          case '/api/workspace-runtime/poll':
            await Future<void>.delayed(const Duration(milliseconds: 10));
            request.response.write(jsonEncode({
              'cursor': delivered ? decoded['cursor'] : 'opaque-cursor-2',
              'events': delivered
                  ? const []
                  : [
                      {
                        'contract': 'conclave.desktop-auth-transport',
                        'version': '1.0',
                        'eventId': 'downstream-1',
                        'occurredAt': DateTime.now().toUtc().toIso8601String(),
                        'message': {'type': 'workspace.hello.ack'},
                      }
                    ],
              'serverTime': DateTime.now().toUtc().toIso8601String(),
              'timedOut': false,
            }));
            delivered = true;
          case '/api/workspace-runtime/sessions/session-1/close':
            closed = true;
            request.response.write(jsonEncode({'closed': true}));
          default:
            request.response.statusCode = HttpStatus.notFound;
            request.response.write(jsonEncode({'error': 'not found'}));
        }
        await request.response.close();
      }
    }();

    final transport = await HttpLongPollWorkspaceTransport.connect(
      baseUri: Uri(scheme: 'http', host: '127.0.0.1', port: server.port),
      workspaceRuntimeId: 'runtime-1',
      runtimeCredential: 'runtime-secret',
    );
    final inbound =
        transport.messages.first.timeout(const Duration(seconds: 2));
    transport.send(jsonEncode({
      'protocol': 'conclave.workspace-runtime',
      'protocolVersion': '5.0',
      'messageId': 'hello-1',
      'type': 'workspace.hello',
    }));
    final eventEnvelope =
        await postedEvents.future.timeout(const Duration(seconds: 2));
    expect(eventEnvelope['sessionId'], 'session-1');
    final event = (eventEnvelope['events'] as List).single as Map;
    expect(event['message']['type'], 'workspace.hello');
    expect(await inbound, contains('workspace.hello.ack'));
    await transport.close();
    expect(closed, isTrue);

    await server.close(force: true);
    await serving;
  });
}
