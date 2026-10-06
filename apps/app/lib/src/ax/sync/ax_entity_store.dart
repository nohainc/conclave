/// Typed normalized table. Replacing one collection preserves other owners.
class AxEntityStore<T> {
  AxEntityStore({required this.idOf});
  final String Function(T) idOf;
  final _entities = <String, T>{};
  final _collections = <String, List<String>>{};
  T? peek(String id) => _entities[id];
  Map<String, T> get entities => Map.unmodifiable(_entities);
  List<String> ids(String collection) => _collections[collection] ?? const [];
  List<T> values(String collection) => List.unmodifiable(
      ids(collection).map((id) => _entities[id]).whereType<T>());
  void upsert(Iterable<T> values) {
    _entities.addAll({for (final value in values) idOf(value): value});
  }

  void replaceCollection(String collection, Iterable<T> values) {
    final additions = {for (final value in values) idOf(value): value};
    _entities.addAll(additions);
    _collections[collection] = List.unmodifiable(additions.keys);
  }

  void remove(String id) {
    _entities.remove(id);
    for (final key in _collections.keys.toList()) {
      _collections[key] =
          List.unmodifiable(_collections[key]!.where((v) => v != id));
    }
  }

  void clear() {
    _entities.clear();
    _collections.clear();
  }
}
