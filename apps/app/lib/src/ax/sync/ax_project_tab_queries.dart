import '../ax_data.dart';
import '../ax_models.dart';
import 'ax_project_workstreams.dart';
import 'ax_sync_engine.dart';

/// Tab resources register and fetch only when a consumer observes/ensures them.
class AxProjectTabQueries {
  AxProjectTabQueries(this.source, {AxSyncEngine? engine})
      : engine = engine ?? AxSyncEngine();
  final AxDataSource source;
  final AxSyncEngine engine;
  static final _sources = Expando<AxProjectTabQueries>();
  static AxProjectTabQueries forSource(AxDataSource source) =>
      _sources[source] ??= AxProjectTabQueries(source);
  late final workstreams = AxProjectWorkstreams(source, engine: engine);

  AxQuery<List<AxProjectMember>> members(String id) => AxQuery(
      key: AxQueryKey(['project', id, 'members']),
      load: () async =>
          List.unmodifiable(await source.loadProjectMembers(projectId: id)));
  AxQuery<List<AxProjectInvitation>> invitations(String id) => AxQuery(
      key: AxQueryKey(['project', id, 'invitations']),
      load: () async => List.unmodifiable(
          await source.loadProjectInvitations(projectId: id)));
  AxQuery<List<AxAuditEntry>> audit(String id) => AxQuery(
      key: AxQueryKey(['project', id, 'audit']),
      load: () async =>
          List.unmodifiable(await source.loadProjectAudit(projectId: id)));
  late final ownedWorkspaces = AxQuery<List<AxWorkspace>>(
      key: AxQueryKey(['workspaces']),
      staleTime: const Duration(seconds: 30),
      load: () async => List.unmodifiable(await source.loadWorkspaces()));

  Future<void> refreshMembers(String id,
      {bool includeMembers = true, bool includeInvitations = true}) async {
    final keys = {
      if (includeMembers) members(id).key,
      if (includeInvitations) invitations(id).key,
    };
    await engine.revalidateWhere(keys.contains);
    engine.invalidate(audit(id).key);
  }
}
