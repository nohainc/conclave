import 'dart:async';
import 'dart:js_interop';
import 'package:web/web.dart' as web;
import 'ax_read_cache_backend.dart';

AxReadCacheBackend? createAxReadCacheBackend() => IndexedDbAxReadCacheBackend();

class IndexedDbAxReadCacheBackend implements AxReadCacheBackend {
  Future<web.IDBDatabase>? _opening;
  bool _closed = false;
  Future<JSAny?> _request(web.IDBRequest request) {
    final result = Completer<JSAny?>();
    request.addEventListener(
        'success',
        ((web.Event _) {
          if (!result.isCompleted) result.complete(request.result);
        }).toJS);
    request.addEventListener(
        'error',
        ((web.Event _) {
          if (!result.isCompleted) {
            result.completeError(StateError(
                request.error?.message ?? 'IndexedDB request failed'));
          }
        }).toJS);
    return result.future;
  }

  Future<void> _completed(web.IDBTransaction transaction) {
    final result = Completer<void>();
    transaction.addEventListener(
        'complete',
        ((web.Event _) {
          if (!result.isCompleted) result.complete();
        }).toJS);
    void fail(web.Event _) {
      if (!result.isCompleted) {
        result.completeError(StateError(
            transaction.error?.message ?? 'IndexedDB transaction aborted'));
      }
    }

    transaction.addEventListener('abort', fail.toJS);
    transaction.addEventListener('error', fail.toJS);
    return result.future;
  }

  Future<web.IDBDatabase> _database() => _opening ??= () async {
        final request =
            web.window.indexedDB.open('conclave-ax-read-cache-v1', 1);
        request.addEventListener(
            'upgradeneeded',
            ((web.Event _) {
              (request.result as web.IDBDatabase).createObjectStore('users');
            }).toJS);
        final db = await _request(request) as web.IDBDatabase;
        db.addEventListener(
            'versionchange',
            ((web.Event _) {
              db.close();
            }).toJS);
        if (_closed) {
          db.close();
          throw StateError('Read cache closed');
        }
        return db;
      }();
  AxReadCacheSnapshot _snapshot(JSAny? value) {
    final data = value.dartify();
    if (data is! Map) return const AxReadCacheSnapshot(0, []);
    final revision = data['revision'] as int? ?? 0;
    if (data['schemaVersion'] != 1) return AxReadCacheSnapshot(revision, []);
    return AxReadCacheSnapshot(
        revision,
        (data['records'] as List? ?? [])
            .map((item) => Map<String, dynamic>.from(item as Map))
            .toList());
  }

  @override
  Future<AxReadCacheSnapshot> read(String userId) async {
    final db = await _database();
    final transaction = db.transaction('users'.toJS, 'readonly');
    final done = _completed(transaction);
    try {
      return _snapshot(
          await _request(transaction.objectStore('users').get(userId.toJS)));
    } finally {
      await done;
    }
  }

  @override
  Future<bool> write(
      String userId, int revision, List<Map<String, dynamic>> records) async {
    final db = await _database();
    final transaction = db.transaction('users'.toJS, 'readwrite');
    final done = _completed(transaction);
    try {
      final store = transaction.objectStore('users');
      final current = _snapshot(await _request(store.get(userId.toJS)));
      if (current.revision != revision) return false;
      await _request(store.put(
          {'schemaVersion': 1, 'revision': revision, 'records': records}
              .jsify(),
          userId.toJS));
      return true;
    } finally {
      await done;
    }
  }

  @override
  Future<void> clear(String userId) async {
    final db = await _database();
    final transaction = db.transaction('users'.toJS, 'readwrite');
    final done = _completed(transaction);
    try {
      final store = transaction.objectStore('users');
      final current = _snapshot(await _request(store.get(userId.toJS)));
      // Only a non-secret revision tombstone remains after logout.
      await _request(store.put(
          {'schemaVersion': 1, 'revision': current.revision + 1, 'records': []}
              .jsify(),
          userId.toJS));
    } finally {
      await done;
    }
  }

  @override
  void close() {
    _closed = true;
    _opening?.then((db) => db.close(), onError: (Object _) {});
  }
}
