import 'ax_query_key.dart';

/// Use one result type and stale duration for each structural key.
/// Loaders delegate to existing AxDataSource methods without cache side effects.
class AxQuery<T> {
  AxQuery(
      {required this.key,
      required this.load,
      this.staleTime = const Duration(minutes: 1)}) {
    if (staleTime.isNegative) throw ArgumentError.value(staleTime, 'staleTime');
  }
  final AxQueryKey key;
  final Future<T> Function() load;
  final Duration staleTime;
}

/// Immutable observation; nullable data and missing data are distinct.
class AxQueryState<T> {
  const AxQueryState(
      {this.data,
      this.hasData = false,
      this.isFetching = false,
      this.isStale = true,
      this.lastFetchedAt,
      this.lastAccessedAt,
      this.error,
      this.generation = 0});
  final T? data;
  final bool hasData;
  final bool isFetching;
  final bool isStale;
  final DateTime? lastFetchedAt;
  final DateTime? lastAccessedAt;
  final Object? error;
  final int generation;
}
