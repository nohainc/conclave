import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/ax/ax_stores.dart';
import 'package:conclave_app/src/ax/ax_models.dart';
import 'ax_fixture_data.dart';

class WorkspaceRecoverySource extends AxFixtureDataSource {
  int workspaceReads = 0;
  int workerReads = 0;
  int bootstraps = 0;
  final state = Completer<List<AxWorkspace>>();
  final inventory = Completer<List<AxWorker>>();
  @override
  Future<List<AxWorkspace>> loadWorkspaces() {
    workspaceReads++;
    return state.future;
  }

  @override
  Future<List<AxWorker>> loadWorkspaceWorkerInventory() {
    workerReads++;
    return inventory.future;
  }

  @override
  Future<AxSnapshot> loadBootstrapState(
      {String? spaceId, String? workspaceId}) {
    bootstraps++;
    return super.loadBootstrapState(spaceId: spaceId, workspaceId: workspaceId);
  }
}

void main() {
  AxWorkspace workspace(String id, String name) =>
      AxWorkspace.fromJson({'id': id, 'name': name});
  test('Workspace gap shares reads and retains other Workspace state',
      () async {
    final source = WorkspaceRecoverySource();
    final store = AxStore(source);
    final old = workspace('A', 'cached');
    final other = workspace('B', 'other');
    store.workspaces.replace([old, other]);
    final first = store.resynchronizeWorkspace('A');
    final second = store.resynchronizeWorkspace('A');
    expect(store.workspaces.items, [old, other]);
    expect(source.workspaceReads, 1);
    expect(source.workerReads, 1);
    source.state
        .complete([workspace('A', 'updated'), workspace('B', 'ignored')]);
    source.inventory.complete([]);
    await Future.wait([first, second]);
    expect(store.workspaces.items.first, same(other));
    expect(store.workspaces.items.last.name, 'updated');
    expect(source.bootstraps, 0);
  });
  test('Cleared session rejects delayed Workspace recovery', () async {
    final source = WorkspaceRecoverySource();
    final store = AxStore(source);
    final old = workspace('A', 'cached');
    store.workspaces.replace([old]);
    final recovery = store.resynchronizeWorkspace('A');
    final check = expectLater(recovery, throwsStateError);
    store.clearServerState();
    source.state.complete([workspace('A', 'late')]);
    source.inventory.complete([]);
    await check;
    expect(store.workspaces.items, isEmpty);
  });
  test('Failed inventory recovery keeps the cached Workspace', () async {
    final source = WorkspaceRecoverySource();
    final store = AxStore(source);
    final old = workspace('A', 'cached');
    store.workspaces.replace([old]);
    final check =
        expectLater(store.resynchronizeWorkspace('A'), throwsStateError);
    source.state.complete([workspace('A', 'updated')]);
    source.inventory.completeError(StateError('offline'));
    await check;
    expect(store.workspaces.items, [old]);
  });
}
