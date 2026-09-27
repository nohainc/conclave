import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conclave_host/desktop_auth.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('rotates the same desktop session using its current bearer credential',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requestReceived = Completer<void>();
    server.listen((request) async {
      expect(request.method, 'POST');
      expect(request.uri.path, '/api/desktop-auth/sessions/session-a/rotate');
      expect(request.headers.value(HttpHeaders.authorizationHeader),
          'Bearer current-session-secret');
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'credential': 'rotated-session-secret',
        'sessionId': 'session-a',
        'audience': 'conclave.desktop.management',
        'user': {
          'userId': 'user-a',
          'displayName': 'User A',
          'email': 'a@example.com',
        },
        'expiresAt': DateTime.now()
            .toUtc()
            .add(const Duration(days: 30))
            .toIso8601String(),
      }));
      await request.response.close();
      requestReceived.complete();
    });

    final client = DesktopAuthClient(
      cloudUrl: 'http://127.0.0.1:${server.port}',
    );
    addTearDown(client.close);
    final rotated = await client.rotateSession(DesktopHumanSession(
      credential: 'current-session-secret',
      sessionId: 'session-a',
      userId: 'user-a',
      displayName: 'User A',
      email: 'a@example.com',
      expiresAt: DateTime.now().toUtc().add(const Duration(days: 2)),
    ));
    await requestReceived.future;

    expect(rotated.credential, 'rotated-session-secret');
    expect(rotated.sessionId, 'session-a');
    expect(rotated.userId, 'user-a');
  });

  test('rejects a rotated session that changes user or session identity',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'credential': 'rotated-session-secret',
        'sessionId': 'another-session',
        'audience': 'conclave.desktop.management',
        'user': {
          'userId': 'user-b',
          'displayName': 'User B',
          'email': 'b@example.com',
        },
        'expiresAt': DateTime.now()
            .toUtc()
            .add(const Duration(days: 30))
            .toIso8601String(),
      }));
      await request.response.close();
    });

    final client = DesktopAuthClient(
      cloudUrl: 'http://127.0.0.1:${server.port}',
    );
    addTearDown(client.close);
    await expectLater(
      client.rotateSession(DesktopHumanSession(
        credential: 'current-session-secret',
        sessionId: 'session-a',
        userId: 'user-a',
        displayName: 'User A',
        email: 'a@example.com',
        expiresAt: DateTime.now().toUtc().add(const Duration(days: 2)),
      )),
      throwsA(isA<FormatException>()),
    );
  });
}
