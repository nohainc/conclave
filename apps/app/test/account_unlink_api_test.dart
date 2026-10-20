import 'dart:convert';

import 'package:conclave_app/src/ax/ax_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('unlink sends the local account record ID with authentication',
      () async {
    final api = AxApiClient(
      baseUrl: 'https://app.example/api',
      client: MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/api/auth/unlink-account');
        expect(request.headers['authorization'], 'Bearer session-token');
        expect(jsonDecode(request.body), {'accountId': 'local-record-id'});
        return http.Response('{"status":true}', 200);
      }),
    )..sessionToken = 'session-token';
    await api.unlinkAccount(accountId: 'local-record-id');
  });

  test('unlink preserves server rejection messages', () async {
    final api = AxApiClient(
      baseUrl: 'https://app.example/api',
      client: MockClient((_) async =>
          http.Response('{"message":"Cannot unlink the last account"}', 400)),
    );
    await expectLater(
        api.unlinkAccount(accountId: 'record'),
        throwsA(isA<AxApiException>().having((error) => error.toString(),
            'message', contains('Cannot unlink the last account'))));
  });
}
