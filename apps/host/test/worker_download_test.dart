import 'dart:io';

import 'package:test/test.dart';

import '../bin/conclave_host.dart' show downloadWorkerPackage;

void main() {
  test('downloads authenticated worker bytes within the configured limit',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) {
      expect(request.headers.value(HttpHeaders.authorizationHeader),
          'Bearer host-token');
      request.response.add([1, 2, 3]);
      request.response.close();
    });
    try {
      final bytes = await downloadWorkerPackage(
        Uri.http('127.0.0.1:${server.port}', '/'),
        'host-token',
        'echo',
        '1.0.0',
        'workers/echo/1.0.0/package.bin',
        maxPackageBytes: 3,
      );
      expect(bytes, [1, 2, 3]);
    } finally {
      await subscription.cancel();
      await server.close(force: true);
    }
  });

  test('rejects an oversized worker response before retaining it', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) {
      request.response.add([1, 2, 3, 4]);
      request.response.close();
    });
    try {
      await expectLater(
        downloadWorkerPackage(
          Uri.http('127.0.0.1:${server.port}', '/'),
          null,
          'echo',
          '1.0.0',
          'workers/echo/1.0.0/package.bin',
          maxPackageBytes: 3,
        ),
        throwsA(predicate((error) =>
            error.toString().contains('exceeds the 3 byte package limit'))),
      );
    } finally {
      await subscription.cancel();
      await server.close(force: true);
    }
  });
}
