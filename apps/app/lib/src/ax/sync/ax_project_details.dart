import '../ax_data.dart';
import '../ax_models.dart';
import 'ax_sync_engine.dart';

/// Focused Project details; list summaries never mark this query hydrated.
class AxProjectDetails {
  AxProjectDetails(this.source, {required this.engine});
  final AxDataSource source;
  final AxSyncEngine engine;

  AxQuery<AxProject> query(String projectId) => AxQuery(
        key: AxQueryKey(['project', projectId]),
        load: () async => (await source.loadProject(projectId: projectId))
            .copyWith(workstreams: const []),
      );

  AxProject? peek(String projectId) => engine.peek(query(projectId)).data;
  Future<AxProject> ensure(String projectId) => engine.ensure(query(projectId));

  /// Record a successful server write, fencing any older detail reads.
  Future<AxProject> record(AxProject project) {
    final entity = project.copyWith(workstreams: const []);
    return engine.mutate(AxMutation(
      query: query(project.id),
      optimistic: (_) => entity,
      execute: () async => entity,
    ));
  }
}
