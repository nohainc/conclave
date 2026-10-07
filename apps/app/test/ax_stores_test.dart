import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/ax/ax_stores.dart';
import 'package:conclave_app/src/ax/ax_models.dart';
import 'ax_fixture_data.dart';
import 'ax_fixture_snapshot.dart';

class _BootstrapSource extends AxFixtureDataSource {
  const _BootstrapSource();

  @override
  Future<AxSnapshot> loadBootstrapState({String? projectId, String? workspaceId}) async {
    final base = axFixtureSnapshot();
    return AxSnapshot(
      viewer: const AxViewer(id: 'user-1', displayName: 'User One', email: 'user@example.test'),
      projects: base.projects,
      workspaces: base.workspaces,
      tasks: base.tasks,
      findings: base.findings,
      events: base.events,
      artifacts: base.artifacts,
      run: base.run,
      activeRunId: base.activeRunId,
      workspaceId: base.workspaceId,
    );
  }
}

void main() {
  group('AxStore Phase 23 facade removal and projection isolation', () {
    test('loadBootstrapState initializes independent stores and strips nested workstreams', () async {
      final source = const _BootstrapSource();
      final store = AxStore(source);
      addTearDown(store.dispose);

      final bootstrap = await store.loadBootstrapState(
        projectId: 'project-auth',
        workspaceId: 'workspace-fixture',
      );

      expect(bootstrap.projects, isNotEmpty);
      for (final project in bootstrap.projects) {
        expect(project.workstreams, isEmpty,
            reason: 'Bootstrap snapshot projects must discard nested workstreams');
      }

      expect(store.projects.items, isNotEmpty);
      for (final project in store.projects.items) {
        expect(project.workstreams, isEmpty,
            reason: 'ProjectStore items must discard nested workstreams');
      }

      expect(store.workspaces.items, isNotEmpty);
      expect(store.auth.viewer?.id, 'user-1');
    });

    test('AxStore.execution returns immutable collections', () {
      final source = const AxFixtureDataSource();
      final store = AxStore(source);
      addTearDown(store.dispose);

      final snapshot = axFixtureSnapshot();
      store.replaceExecution(snapshot);

      final exec = store.execution;
      expect(exec.run, isNotNull);
      expect(exec.projects, isEmpty,
          reason: 'Legacy execution projection excludes projects');

      // Check unmodifiable list guarantees
      if (exec.tasks.isNotEmpty) {
        expect(() => (exec.tasks as dynamic).add(exec.tasks.first),
            throwsA(isA<UnsupportedError>()));
      }
      if (exec.findings.isNotEmpty) {
        expect(() => (exec.findings as dynamic).add(exec.findings.first),
            throwsA(isA<UnsupportedError>()));
      }
      if (exec.events.isNotEmpty) {
        expect(() => (exec.events as dynamic).add(exec.events.first),
            throwsA(isA<UnsupportedError>()));
      }
      if (exec.artifacts.isNotEmpty) {
        expect(() => (exec.artifacts as dynamic).add(exec.artifacts.first),
            throwsA(isA<UnsupportedError>()));
      }
      if (exec.candidateOutputs.isNotEmpty) {
        expect(() => (exec.candidateOutputs as dynamic).add(exec.candidateOutputs.first),
            throwsA(isA<UnsupportedError>()));
      }
    });

    test('replaceExecution notifies executionChanges without touching queries or session', () {
      final source = const AxFixtureDataSource();
      final store = AxStore(source);
      addTearDown(store.dispose);

      int executionSignals = 0;
      store.executionChanges.addListener(() {
        executionSignals++;
      });

      final snapshot = axFixtureSnapshot();
      store.replaceExecution(snapshot);

      expect(executionSignals, 1);
      expect(store.execution.run?.id, snapshot.run?.id);
      expect(store.projects.items, isEmpty,
          reason: 'replaceExecution must not write project queries');
      expect(store.workspaces.items, isEmpty,
          reason: 'replaceExecution must not write workspace queries');
    });

    test('collaboration mutations and query updates do not trigger executionChanges', () {
      final source = const AxFixtureDataSource();
      final store = AxStore(source);
      addTearDown(store.dispose);

      int executionSignals = 0;
      store.executionChanges.addListener(() {
        executionSignals++;
      });

      store.projects.replace([
        const AxProject(
          id: 'p1',
          name: 'P1',
          branch: 'main',
          lastActivity: 'now',
        ),
      ]);

      store.workspaces.replace([
        const AxWorkspace(
          id: 'w1',
          name: 'W1',
          slug: 'w1',
          status: 'active',
          role: 'owner',
        ),
      ]);

      expect(executionSignals, 0,
          reason: 'Query updates must not trigger execution projection signals');
      expect(store.projects.items.length, 1);
      expect(store.workspaces.items.length, 1);
    });

    test('clearServerState resets queries, auth, security, and execution projection', () async {
      final source = const AxFixtureDataSource();
      final store = AxStore(source);
      addTearDown(store.dispose);

      await store.loadBootstrapState();
      expect(store.projects.items, isNotEmpty);
      expect(store.workspaces.items, isNotEmpty);

      store.clearServerState();

      expect(store.projects.items, isEmpty);
      expect(store.workspaces.items, isEmpty);
      expect(store.security.value, isNull);
      expect(store.execution.run, isNull);
      expect(store.execution.tasks, isEmpty);
      expect(store.execution.findings, isEmpty);
    });

    test('superseded or disposed bootstrap throws StateError', () async {
      final source = const AxFixtureDataSource();
      final store = AxStore(source);
      store.dispose();

      expect(() => store.loadBootstrapState(),
          throwsA(isA<StateError>()));
    });
  });
}
