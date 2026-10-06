import 'dart:convert';

class AxReadCacheSnapshot {
  const AxReadCacheSnapshot(this.revision, this.records);
  final int revision;
  final List<Map<String, dynamic>> records;
}

/// A revision fences writers in other tabs after a user cache is cleared.
abstract interface class AxReadCacheBackend {
  Future<AxReadCacheSnapshot> read(String userId);
  Future<bool> write(
      String userId, int revision, List<Map<String, dynamic>> records);
  Future<void> clear(String userId);
  void close();
}

class MemoryAxReadCacheBackend implements AxReadCacheBackend {
  final _users = <String, AxReadCacheSnapshot>{};
  List<Map<String, dynamic>> _copy(List<Map<String, dynamic>> records) =>
      (jsonDecode(jsonEncode(records)) as List).cast<Map<String, dynamic>>();
  @override
  Future<AxReadCacheSnapshot> read(String userId) async {
    final snapshot = _users[userId] ?? const AxReadCacheSnapshot(0, []);
    return AxReadCacheSnapshot(snapshot.revision, _copy(snapshot.records));
  }

  @override
  Future<bool> write(
      String userId, int revision, List<Map<String, dynamic>> records) async {
    if ((_users[userId]?.revision ?? 0) != revision) return false;
    _users[userId] = AxReadCacheSnapshot(revision, _copy(records));
    return true;
  }

  @override
  Future<void> clear(String userId) async {
    _users[userId] =
        AxReadCacheSnapshot((_users[userId]?.revision ?? 0) + 1, []);
  }

  @override
  void close() {}
}
