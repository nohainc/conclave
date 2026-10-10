import 'package:conclave_app/src/ax/ax_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('private avatars use the authenticated API origin and keep version',
      () async {
    final api = AxApiClient(
      baseUrl: 'https://app.example/api',
      client: MockClient((request) async {
        expect(request.url.toString(),
            'https://app.example/api/users/user-1/avatar?v=image-2');
        expect(request.headers['authorization'], 'Bearer session-token');
        expect(request.headers['accept'], 'image/*');
        return http.Response.bytes([1, 2, 3], 200);
      }),
    )..sessionToken = 'session-token';
    expect(
        await api.loadAvatar(
            url: 'https://cloud.example/api/users/user-1/avatar?v=image-2'),
        [1, 2, 3]);
  });

  test('avatar authentication failures are reported', () async {
    final api = AxApiClient(
      baseUrl: 'https://app.example/api',
      client: MockClient((_) async => http.Response('', 401)),
    );
    await expectLater(api.loadAvatar(url: '/api/users/user-1/avatar'),
        throwsA(isA<AxApiException>()));
  });
}
