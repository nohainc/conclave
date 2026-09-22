import 'dart:convert';
import 'dart:io';

/// Resolves Cloud repository identities to explicitly registered local paths.
/// The registry is local Host state; Cloud never supplies filesystem paths.
class LocalRepositoryRegistry {
  LocalRepositoryRegistry._(this._paths);

  final Map<String, String> _paths;

  static Future<LocalRepositoryRegistry> load(File file) async {
    if (!await file.exists()) return LocalRepositoryRegistry._({});
    if (await file.length() > 64 * 1024) {
      throw StateError('repository registry exceeds the 64 KB limit');
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) {
      throw StateError('repository registry must be a JSON object');
    }
    final paths = <String, String>{};
    for (final entry in decoded.entries) {
      if (entry.key is! String || entry.value is! String) {
        throw StateError('repository registry entries must be strings');
      }
      final id = entry.key as String;
      final path = entry.value as String;
      _validateId(id);
      if (path.isEmpty) throw StateError('repository path is required for $id');
      final directory = Directory(path);
      if (!await directory.exists()) {
        throw StateError('registered repository does not exist: $id');
      }
      paths[id] = await directory.resolveSymbolicLinks();
    }
    return LocalRepositoryRegistry._(paths);
  }

  Future<String?> resolve(String repositoryId) async {
    _validateId(repositoryId);
    final path = _paths[repositoryId];
    if (path == null) return null;
    final directory = Directory(path);
    if (!await directory.exists()) return null;
    final resolved = await directory.resolveSymbolicLinks();
    if (resolved != path) {
      // A registered path changing underneath the Host is not accepted.
      return null;
    }
    return path;
  }

  static void _validateId(String value) {
    if (value.trim().isEmpty || value.contains('/') || value.contains('\\')) {
      throw StateError('repository id must be a single non-empty identifier');
    }
  }
}
