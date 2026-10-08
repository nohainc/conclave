@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/ax/ax_models.dart';
import 'package:conclave_app/src/ax/ax_stores.dart';
import 'ax_fixture_data.dart';
import 'package:conclave_app/src/ax/sync/persistence/ax_read_cache_platform_web.dart';

void main() {
  test(
      'native structured cache hydrates typed Space state then clears on logout',
      () async {
    final user = 'typed-browser-${DateTime.now().microsecondsSinceEpoch}';
    final first = AxStore(const AxFixtureDataSource());
    expect(first.persistence.backend, isA<IndexedDbAxReadCacheBackend>());
    first.auth.session = AxSession(
        authenticated: true,
        viewer: AxViewer(id: user, displayName: 'User', email: 'private@test'));
    await first.hydrateReadCache();
    first.spaces.replace([
      const AxSpace(
          id: 'P', name: 'Persisted Space', branch: 'main', lastActivity: 'now')
    ]);
    await first.persistence.flush();
    final second = AxStore(const AxFixtureDataSource());
    second.auth.session = first.auth.session;
    expect(await second.hydrateReadCache(), isTrue);
    expect(second.spaces.items.single.name, 'Persisted Space');
    await second.logout();
    final check = IndexedDbAxReadCacheBackend();
    expect((await check.read(user)).records, isEmpty);
    first.dispose();
    second.dispose();
    check.close();
  });

  test(
      'native IndexedDB survives reopen, isolates users and fences logout writers',
      () async {
    final user = 'browser-test-${DateTime.now().microsecondsSinceEpoch}';
    final backend = IndexedDbAxReadCacheBackend();
    final empty = await backend.read(user);
    final records = [
      {
        'version': 1,
        'key': ['spaces'],
        'data': [
          {'id': 'P', 'name': 'Cached'}
        ]
      }
    ];
    expect(await backend.write(user, empty.revision, records), isTrue);
    final reopened = IndexedDbAxReadCacheBackend();
    expect((await reopened.read(user)).records, records);
    expect((await reopened.read('$user-other')).records, isEmpty);
    await reopened.clear(user);
    expect((await backend.read(user)).records, isEmpty);
    expect(await backend.write(user, empty.revision, records), isFalse);
    backend.close();
    reopened.close();
  });
}
