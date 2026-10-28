import 'package:syntila_app/src/ax/ax_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('avatar uploads send original and thumbnail as authenticated multipart',
      () async {
    final api = AxApiClient(
      baseUrl: 'https://app.example/api',
      client: MockClient((request) async {
        expect(request.method, 'PUT');
        expect(request.headers['authorization'], 'Bearer token');
        expect(request.headers['content-type'],
            startsWith('multipart/form-data;'));
        expect(request.body, contains('name="original"'));
        expect(request.body, contains('name="thumbnail"'));
        expect(request.body, contains('content-type: image/jpeg'));
        expect(request.body, contains('content-type: image/png'));
        return http.Response(
            '{"avatarUrl":"https://app.example/api/users/a/avatar?v=1"}', 200);
      }),
    )..sessionToken = 'token';
    expect(
        await api.uploadAvatar(
            bytes: [1, 2], mediaType: 'image/jpeg', thumbnailBytes: [3]),
        contains('avatar?v=1'));
  });

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
