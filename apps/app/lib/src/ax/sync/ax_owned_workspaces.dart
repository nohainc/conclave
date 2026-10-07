import '../ax_data.dart';
import '../ax_models.dart';
import 'ax_sync_engine.dart';

/// All consumers of this shared key use the same freshness policy and shape.
AxQuery<List<AxWorkspace>> ownedWorkspacesQuery(AxDataSource source) => AxQuery(
    key: AxQueryKey(['workspaces']),
    staleTime: const Duration(seconds: 30),
    load: () async => List.unmodifiable(await source.loadWorkspaces()));
