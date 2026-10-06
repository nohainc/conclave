import 'ax_idempotency.dart';
import '../ax_data.dart';
import '../ax_models.dart';
import 'ax_project_details.dart';
import 'ax_project_workstreams.dart';
import 'ax_sync_engine.dart';

/// Shared collaboration writes. Widgets own form state and notifications only.
class AxCollaborationMutations {
  AxCollaborationMutations(this.source, {required this.engine});
  final AxDataSource source;
  final AxSyncEngine engine;
  final _attempts = AxMutationAttempts();
  void clear() => _attempts.clear();
  int _nextId = 0;
  late final details = AxProjectDetails(source, engine: engine);
  late final workstreams = AxProjectWorkstreams(source, engine: engine);
  late final projects = AxQuery<List<AxProject>>(
      key: AxQueryKey(['projects']),
      load: () async => List.unmodifiable((await source.loadProjects())
          .map((p) => p.copyWith(workstreams: const []))));

  String _temporary(String kind) =>
      'local-$kind-${DateTime.now().microsecondsSinceEpoch}-${++_nextId}';
  List<T> _put<T>(List<T> values, T value, String Function(T) id) =>
      List.unmodifiable([
        for (final item in values)
          if (id(item) != id(value)) item,
        value,
      ]);
  List<T> _replace<T>(List<T> values, T value, String Function(T) id) =>
      List.unmodifiable(values.any((item) => id(item) == id(value))
          ? values.map((item) => id(item) == id(value) ? value : item)
          : [...values, value]);

  Future<AxProject> createProject(
      {required String name, String? description, String? instructions}) {
    final local = AxProject(
        id: _temporary('project'),
        name: name,
        description: description ?? '',
        instructions: instructions ?? '',
        branch: 'main',
        lastActivity: 'now');
    return engine.mutations.run(
        AxMutationOperation<AxProject, AxOptimisticUpdate<List<AxProject>>>(
      optimisticUpdate: () => engine.optimisticUpdate(
          projects, (state) => _put(state.data ?? [], local, (p) => p.id)),
      isCurrent: (change) => change.isCurrent(),
      execute: (_) async {
        final value = await source.createProject(
            name: name, description: description, instructions: instructions);
        if (value.id.isEmpty || value.id.startsWith('local-')) {
          throw const AxApiException(
              'Project response identity does not match');
        }
        return value.copyWith(workstreams: const []);
      },
      commit: (saved, change) {
        change.commit((state) => _put(
            (state.data ?? []).where((p) => p.id != local.id).toList(),
            saved,
            (p) => p.id));
        engine.update(details.query(saved.id), (_) => saved);
      },
      rollback: (_, __, change) => change.rollback(),
      invalidate: (saved, _) async {
        engine.invalidate(projects.key);
      },
    ));
  }

  Future<AxProject> editProject(AxProject original,
      {String? name,
      String? description,
      String? instructions,
      Map<String, dynamic>? settings}) {
    final query = details.query(original.id);
    AxProject patch(AxProject value) => value.copyWith(
        name: name,
        description: description,
        instructions: instructions,
        settings: settings,
        archived: settings?['archived'] is bool
            ? settings!['archived'] as bool
            : null,
        workstreams: const []);
    return engine.mutations.run(AxMutationOperation<AxProject,
        (AxOptimisticUpdate<AxProject>, AxOptimisticUpdate<List<AxProject>>)>(
      key: AxQueryKey(['mutation', 'project', original.id]),
      optimisticUpdate: () {
        final detailChange = engine.optimisticUpdate(
            query, (state) => patch(state.data ?? original));
        final listChange = engine.optimisticUpdate(projects, (state) {
          final values = state.data ?? const <AxProject>[];
          if (!detailChange.isCurrent()) return values;
          final latest =
              values.where((p) => p.id == original.id).firstOrNull ?? original;
          return _replace(values, patch(latest), (p) => p.id);
        });
        return (detailChange, listChange);
      },
      isCurrent: (changes) => changes.$1.isCurrent() && changes.$2.isCurrent(),
      cancel: (changes) {
        changes.$1.rollback();
        changes.$2.rollback();
      },
      execute: (_) async {
        final value = await source.updateProject(
            projectId: original.id,
            name: name,
            description: description,
            instructions: instructions,
            settings: settings);
        if (value.id != original.id) {
          throw const AxApiException(
              'Project response identity does not match');
        }
        return value.copyWith(workstreams: const []);
      },
      commit: (saved, changes) {
        changes.$1.commit((_) => saved);
        changes.$2
            .commit((state) => _replace(state.data ?? [], saved, (p) => p.id));
      },
      rollback: (_, __, changes) {
        changes.$1.rollback();
        changes.$2.rollback();
      },
      invalidate: (_, __) async {
        engine.invalidate(AxQueryKey(['project', original.id, 'audit']));
      },
    ));
  }

  Future<AxWorkstream> createWorkstream(
      {required String projectId,
      required String name,
      String? idempotencyKey}) {
    final query = workstreams.query(projectId);
    final input = {'name': name};
    final scope = 'project:$projectId:create-workstream';
    final key = idempotencyKey ?? _attempts.keyFor(scope, input);
    final local = AxWorkstream.fromJson({
      'id': _temporary('workstream'),
      'projectId': projectId,
      'name': name,
      'status': 'active'
    });
    return engine.mutations.run(AxMutationOperation<AxWorkstream,
        AxOptimisticUpdate<List<AxWorkstream>>>(
      key: AxQueryKey(['mutation', 'workstream-create', key]),
      optimisticUpdate: () => engine.optimisticUpdate(
          query, (state) => _put(state.data ?? [], local, (w) => w.id)),
      isCurrent: (change) => change.isCurrent(),
      execute: (_) async {
        final value = await source.createWorkstream(
            projectId: projectId, name: name, idempotencyKey: key);
        if (value.id.isEmpty ||
            value.id.startsWith('local-') ||
            value.projectId != projectId) {
          throw const AxApiException(
              'Workstream response identity does not match');
        }
        return value;
      },
      commit: (saved, change) {
        _attempts.complete(scope, input, key);
        change.commit((state) => _put(
            (state.data ?? []).where((w) => w.id != local.id).toList(),
            saved,
            (w) => w.id));
      },
      rollback: (_, __, change) => change.rollback(),
      invalidate: (_, __) async {
        engine.invalidate(AxQueryKey(['project', projectId, 'audit']));
      },
    ));
  }

  Future<AxWorkstream> editWorkstream(AxWorkstream original,
      {String? name, String? status, Map<String, dynamic>? workConfig}) {
    final query = workstreams.query(original.projectId);
    AxWorkstream patch(AxWorkstream value) =>
        value.copyWith(name: name, status: status, workConfig: workConfig);
    return engine.mutations.run(AxMutationOperation<AxWorkstream,
        AxOptimisticUpdate<List<AxWorkstream>>>(
      key: AxQueryKey(['mutation', 'workstream', original.id]),
      optimisticUpdate: () => engine.optimisticUpdate(
          query,
          (state) => _replace(
              state.data ?? [],
              patch((state.data ?? [])
                      .where((w) => w.id == original.id)
                      .firstOrNull ??
                  original),
              (w) => w.id)),
      isCurrent: (change) => change.isCurrent(),
      execute: (_) async {
        final value = await source.updateWorkstream(
            workstreamId: original.id,
            name: name,
            status: status,
            workConfig: workConfig);
        if (value.id != original.id || value.projectId != original.projectId) {
          throw const AxApiException(
              'Workstream response identity does not match');
        }
        return value;
      },
      commit: (saved, change) => change
          .commit((state) => _replace(state.data ?? [], saved, (w) => w.id)),
      rollback: (_, __, change) => change.rollback(),
      invalidate: (_, __) async {
        engine.invalidate(AxQueryKey(['project', original.projectId, 'audit']));
      },
    ));
  }

  Future<void> deleteWorkstream(AxWorkstream original) {
    final query = workstreams.query(original.projectId);
    List<AxWorkstream> remove(AxQueryState<List<AxWorkstream>> state) =>
        List.unmodifiable((state.data ?? []).where((w) => w.id != original.id));
    return engine.mutations
        .run(AxMutationOperation<void, AxOptimisticUpdate<List<AxWorkstream>>>(
      key: AxQueryKey(['mutation', 'workstream', original.id]),
      optimisticUpdate: () => engine.optimisticUpdate(query, remove),
      isCurrent: (change) => change.isCurrent(),
      execute: (_) => source.deleteWorkstream(workstreamId: original.id),
      commit: (_, change) {
        change.commit(remove);
        engine.remove(AxQueryKey(['workstream', original.id]), prefix: true);
      },
      rollback: (_, __, change) => change.rollback(),
      invalidate: (_, __) async {
        engine.invalidate(AxQueryKey(['project', original.projectId, 'audit']));
      },
    ));
  }
}
