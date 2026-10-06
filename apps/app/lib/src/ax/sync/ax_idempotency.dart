import 'dart:convert';
import 'dart:math';

/// Opaque client operation identity; never derived from content or credentials.
String newAxIdempotencyKey() {
  final random = Random.secure();
  return List.generate(
      32, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

/// Retains only identities for explicit retries, never executable offline work.
class AxMutationAttempts {
  final _keys = <String, String>{};
  final _submitted = <String>{};
  bool wasSubmitted(String key) => _submitted.contains(key);
  void markSubmitted(String key) => _submitted.add(key);
  String _fingerprint(String scope, Object? input) {
    Object? canonical(Object? value) {
      if (value is List) return value.map(canonical).toList();
      if (value is Map) {
        final keys = value.keys.cast<String>().toList()..sort();
        return {for (final key in keys) key: canonical(value[key])};
      }
      return value;
    }

    return jsonEncode([scope, canonical(input)]);
  }

  String keyFor(String scope, Object? input) =>
      _keys.putIfAbsent(_fingerprint(scope, input), newAxIdempotencyKey);
  void complete(String scope, Object? input, String key) {
    final fingerprint = _fingerprint(scope, input);
    if (_keys[fingerprint] == key) {
      _keys.remove(fingerprint);
      _submitted.remove(key);
    }
  }

  void clear() {
    _keys.clear();
    _submitted.clear();
  }
}

/// Freeze authored JSON before asynchronous validation and submission.
dynamic freezeAxMutationInput(dynamic value) => value is Map
    ? Map<String, dynamic>.unmodifiable(value.map(
        (key, item) => MapEntry(key as String, freezeAxMutationInput(item))))
    : value is List
        ? List<dynamic>.unmodifiable(value.map(freezeAxMutationInput))
        : value;
