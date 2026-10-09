import '../ax_data.dart';
import 'ax_sync_engine.dart';

/// One session query shared by People and invitation consumers. No polling or navigation reload.
class AxPeople {
  AxPeople(this.source, {required this.engine});
  final AxDataSource source;
  final AxSyncEngine engine;
  static final key = AxQueryKey(['people']);
  late final query = AxQuery<List<AxPerson>>(
      key: key,
      staleTime: const Duration(minutes: 45),
      load: () async =>
          List.unmodifiable(await (source as AxPeopleDataSource).loadPeople()));
  Future<List<AxPerson>> ensure() =>
      engine.ensure(query, policy: AxCachePolicy.cacheFirst);
  Future<List<AxPerson>> refresh() => engine.refresh(query);
  void clear() => engine.remove(key);
}
