import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:conclave_app/src/ax/ax_data.dart';

http.Response space(String id, String name, {String? etag}) => http.Response(
    jsonEncode({
      'space': {'id': id, 'name': name}
    }),
    200,
    headers: {if (etag != null) 'etag': etag});
void main() {
  test('stable resources send validators and reuse their typed result on 304',
      () async {
    final requests = <http.Request>[];
    final api = AxApiClient(
        baseUrl: 'https://test/api',
        client: MockClient((r) async {
          requests.add(r);
          if (r.headers['if-none-match'] != null) return http.Response('', 304);
          if (r.url.path.endsWith('/threads')) {
            return http.Response('{"threads":[]}', 200,
                headers: {'etag': '"streams"'});
          }
          if (r.url.path.endsWith('/catalog')) {
            return http.Response('{"workflows":[]}', 200,
                headers: {'etag': '"catalog"'});
          }
          return space('p', 'Space', etag: '"space"');
        }));
    for (var i = 0; i < 2; i++) {
      expect((await api.loadSpace(spaceId: 'p')).name, 'Space');
      expect(await api.loadSpaceThreads(spaceId: 'p'), isEmpty);
      expect(await api.loadBuiltinWorkflowCatalog(), isEmpty);
    }
    expect(
        requests.take(3).every((r) => !r.headers.containsKey('if-none-match')),
        isTrue);
    expect(requests.skip(3).map((r) => r.headers['if-none-match']),
        ['"space"', '"streams"', '"catalog"']);
  });
  test(
      'changed representations replace validators; older Cloud without ETags still works',
      () async {
    var calls = 0;
    final api = AxApiClient(
        baseUrl: 'https://test/api',
        client: MockClient((r) async {
          calls++;
          if (calls == 1) return space('p', 'Old', etag: '"old"');
          if (calls == 2) {
            expect(r.headers['if-none-match'], '"old"');
            return space('p', 'New');
          }
          expect(r.headers['if-none-match'], isNull);
          return space('p', 'New');
        }));
    await api.loadSpace(spaceId: 'p');
    expect((await api.loadSpace(spaceId: 'p')).name, 'New');
    await api.loadSpace(spaceId: 'p');
  });
  test('401 never falls back to a cached representation', () async {
    var calls = 0;
    final api = AxApiClient(
        baseUrl: 'https://test/api',
        client: MockClient((_) async => ++calls == 1
            ? space('p', 'Old', etag: '"old"')
            : http.Response('{}', 401)));
    await api.loadSpace(spaceId: 'p');
    await expectLater(
        api.loadSpace(spaceId: 'p'),
        throwsA(
            isA<AxApiException>().having((e) => e.statusCode, 'status', 401)));
  });
  test('token changes, user switches and clearing remove validators', () async {
    var user = 'u1';
    var expectValidator = false;
    final api = AxApiClient(
        baseUrl: 'https://test/api',
        client: MockClient((r) async {
          if (r.url.path.endsWith('/session')) {
            return http.Response(
                jsonEncode({
                  'authenticated': true,
                  'user': {
                    'id': user,
                    'displayName': user,
                    'email': '$user@test'
                  }
                }),
                200);
          }
          expect(r.headers.containsKey('if-none-match'), expectValidator);
          return space('p', 'Space', etag: '"etag"');
        }));
    await api.loadSession();
    await api.loadSpace(spaceId: 'p');
    expectValidator = true;
    await api.loadSpace(spaceId: 'p');
    api.sessionToken = 'new-token';
    expectValidator = false;
    await api.loadSpace(spaceId: 'p');
    user = 'u2';
    await api.loadSession();
    await api.loadSpace(spaceId: 'p');
    api.clearConditionalReads();
    await api.loadSpace(spaceId: 'p');
  });
  test('LRU transport storage is bounded to sixteen representations', () async {
    final api = AxApiClient(
        baseUrl: 'https://test/api',
        client: MockClient((r) async {
          expect(r.headers['if-none-match'], isNull);
          return space(r.url.pathSegments.last, 'Space', etag: '"etag"');
        }));
    for (var i = 0; i < 17; i++) {
      await api.loadSpace(spaceId: '$i');
    }
    await api.loadSpace(spaceId: '0');
  });
  test('late response after clear cannot repopulate transport cache', () async {
    final pending = Completer<http.Response>();
    var calls = 0;
    final api = AxApiClient(
        baseUrl: 'https://test/api',
        client: MockClient((r) async {
          expect(r.headers['if-none-match'], isNull);
          if (++calls == 1) return pending.future;
          return space('p', 'New', etag: '"new"');
        }));
    final old = api.loadSpace(spaceId: 'p');
    await Future<void>.delayed(Duration.zero);
    api.clearConditionalReads();
    pending.complete(space('p', 'Old', etag: '"old"'));
    await old;
    await api.loadSpace(spaceId: 'p');
  });
  test('old slow response cannot replace a newer transport representation',
      () async {
    final pending = Completer<http.Response>();
    var calls = 0;
    final api = AxApiClient(
        baseUrl: 'https://test/api',
        client: MockClient((r) async {
          if (++calls == 1) return pending.future;
          if (calls == 2) return space('p', 'New', etag: '"new"');
          expect(r.headers['if-none-match'], '"new"');
          return http.Response('', 304);
        }));
    final old = api.loadSpace(spaceId: 'p');
    await Future<void>.delayed(Duration.zero);
    await api.loadSpace(spaceId: 'p');
    pending.complete(space('p', 'Old', etag: '"old"'));
    await old;
    expect((await api.loadSpace(spaceId: 'p')).name, 'New');
  });

  test('unsolicited 304 without a retained representation fails explicitly',
      () async {
    final api = AxApiClient(
        baseUrl: 'https://test/api',
        client: MockClient((_) async => http.Response('', 304)));
    await expectLater(
        api.loadSpace(spaceId: 'p'), throwsA(isA<AxApiException>()));
  });
  test('transport byte budget evicts representations before the count limit',
      () async {
    final largeName = 'x' * 230000;
    final api = AxApiClient(
        baseUrl: 'https://test/api',
        client: MockClient((r) async {
          expect(r.headers['if-none-match'], isNull);
          return space(r.url.pathSegments.last, largeName, etag: '"large"');
        }));
    for (var i = 0; i < 5; i++) {
      await api.loadSpace(spaceId: '$i');
    }
    await api.loadSpace(spaceId: '0');
  });

  test('oversized representations never enter the validator cache', () async {
    final api = AxApiClient(
        baseUrl: 'https://test/api',
        client: MockClient((r) async {
          expect(r.headers['if-none-match'], isNull);
          return space('p', 'x' * 270000, etag: '"oversized"');
        }));
    await api.loadSpace(spaceId: 'p');
    await api.loadSpace(spaceId: 'p');
  });
}
