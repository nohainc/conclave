import 'ax_query.dart';

/// A targeted optimistic mutation. Queries affected indirectly can be
/// invalidated by the caller after the authoritative operation succeeds.
class AxMutation<T> {
  const AxMutation(
      {required this.query, required this.execute, this.optimistic});
  final AxQuery<T> query;
  final Future<T> Function() execute;
  final T Function(AxQueryState<T> previous)? optimistic;
}
