import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/ax/ax_stores.dart';
import 'package:conclave_app/src/ax/sync/ax_project_tab_queries.dart';
import 'package:conclave_app/src/ax/sync/ax_sync_engine.dart';
import 'ax_fixture_data.dart';

void main() {
  for (final storeFirst in [true, false]) {
    test(
        'workspace store and project picker share query, storeFirst=$storeFirst',
        () async {
      final source = const AxFixtureDataSource();
      final engine = AxSyncEngine();
      final tabs = AxProjectTabQueries(source, engine: engine);
      if (!storeFirst) await engine.ensure(tabs.ownedWorkspaces);
      final store = WorkspaceStore(source, engine: engine);
      addTearDown(store.dispose);
      await store.list();
      final pickerItems = await engine.ensure(tabs.ownedWorkspaces);
      expect(pickerItems, store.items);
      expect(store.query.staleTime, const Duration(seconds: 30));
      await engine.refresh(tabs.ownedWorkspaces);
      expect(engine.peek(store.query).data, store.items);
    });
  }
}
