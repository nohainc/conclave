import '../ax_data.dart';
import '../ax_models.dart';
import 'ax_sync_engine.dart';

/// User-wide archived Space inventory shared by the archived Spaces page.
class AxArchivedSpaces {
  AxArchivedSpaces(this.source, {required this.engine});

  final AxDataSource source;
  final AxSyncEngine engine;

  static final key = AxQueryKey(['archived-spaces']);

  late final query = AxQuery<List<AxSpace>>(
    key: key,
    staleTime: const Duration(minutes: 5),
    load: () async => List.unmodifiable((await source.loadSpaces(
      includeArchived: true,
    ))
        .where((space) => space.archived)
        .map((space) => space.copyWith(threads: const []))),
  );

  Future<List<AxSpace>> ensure() =>
      engine.ensure(query, policy: AxCachePolicy.networkOnly);

  Future<List<AxSpace>> refresh() => engine.refresh(query);

  void clear() => engine.remove(key);
}
