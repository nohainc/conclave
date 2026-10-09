import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Resolves the user-owned working directory for a Space.
///
/// Directory names are only presentation. The private registry and the
/// marker in each directory bind the path to the immutable Space ID, so a
/// rename never moves user files and a duplicate name cannot collide.
class SpaceDirectoryResolver {
  SpaceDirectoryResolver({
    required this.workRoot,
    required this.registryDirectory,
  });

  final Directory workRoot;
  final Directory registryDirectory;
  Future<void> _tail = Future<void>.value();

  static const _registryFileName = 'space-directories.json';
  static const _markerFileName = '.conclave-space.json';
  static const _schemaVersion = 1;
  static final _safeId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$');

  Future<Directory> resolve({
    required String spaceId,
    required String spaceName,
  }) =>
      _serial(() => _resolve(spaceId: spaceId, spaceName: spaceName));

  Future<Directory> _resolve({
    required String spaceId,
    required String spaceName,
  }) async {
    if (!_safeId.hasMatch(spaceId)) {
      throw ArgumentError.value(spaceId, 'spaceId', 'invalid Space ID');
    }
    await workRoot.create(recursive: true);
    await registryDirectory.create(recursive: true);
    final registry = await _readRegistry();
    var record = registry[spaceId];
    Directory? directory;
    var adoptingLegacy = false;

    if (record != null) {
      final relativePath = record['relativePath'];
      if (relativePath is! String || !_isSafeRelativePath(relativePath)) {
        throw StateError('Space directory registry contains an unsafe path');
      }
      directory = Directory(_join(workRoot.path, relativePath));
      final registeredType = await FileSystemEntity.type(
        directory.path,
        followLinks: false,
      );
      if (registeredType == FileSystemEntityType.link) {
        throw StateError('Space directory cannot be a symbolic link');
      }
      if (!await directory.exists()) {
        directory = await _findMarkedDirectory(spaceId);
      }
    } else {
      directory = await _findMarkedDirectory(spaceId);
      directory ??= await _findLegacySpaceDirectory(spaceId);
      adoptingLegacy = directory != null;
    }

    if (directory == null) {
      final base = _sanitizeName(spaceName);
      var candidate = base;
      var suffix = 2;
      while (true) {
        final path = _join(workRoot.path, candidate);
        final type = await FileSystemEntity.type(path, followLinks: false);
        if (type == FileSystemEntityType.notFound) {
          directory = Directory(path);
          break;
        }
        if (type == FileSystemEntityType.directory &&
            await _markerMatches(Directory(path), spaceId)) {
          directory = Directory(path);
          break;
        }
        candidate = '$base ($suffix)';
        suffix++;
      }
    }

    await directory.create(recursive: true);
    await _ensureMarker(
      directory,
      spaceId: spaceId,
      spaceName: spaceName,
      allowNonEmpty: adoptingLegacy,
    );
    final relativePath = _relativeToRoot(directory.path);
    registry[spaceId] = {
      'spaceId': spaceId,
      'relativePath': relativePath,
      'displayName': spaceName.trim().isEmpty ? 'Space' : spaceName.trim(),
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    };
    await _writeRegistry(registry);
    return directory;
  }

  Future<Directory?> _findMarkedDirectory(String spaceId) async {
    if (!await workRoot.exists()) return null;
    await for (final entity in workRoot.list(followLinks: false)) {
      if (entity is Directory && await _markerMatches(entity, spaceId)) {
        return entity;
      }
    }
    return null;
  }

  /// Recognizes the pre-Space layout (`Work/<spaceId>/<threadId>`) without
  /// moving or deleting anything. The old directory is adopted in place so a
  /// migration never strands existing user repositories.
  Future<Directory?> _findLegacySpaceDirectory(String spaceId) async {
    final candidate = Directory(_join(workRoot.path, spaceId));
    if (await FileSystemEntity.type(candidate.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return null;
    }
    var sawChildDirectory = false;
    await for (final entity in candidate.list(followLinks: false)) {
      if (entity is! Directory) continue;
      sawChildDirectory = true;
      if (!_safeId.hasMatch(entity.path.split(Platform.pathSeparator).last)) {
        return null;
      }
    }
    return sawChildDirectory ? candidate : null;
  }

  Future<bool> _markerMatches(Directory directory, String spaceId) async {
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return false;
    }
    final file = File(_join(directory.path, _markerFileName));
    if (!await file.exists()) return false;
    try {
      final value = jsonDecode(await file.readAsString());
      return value is Map && value['spaceId'] == spaceId;
    } on Object {
      return false;
    }
  }

  Future<void> _ensureMarker(
    Directory directory, {
    required String spaceId,
    required String spaceName,
    required bool allowNonEmpty,
  }) async {
    final marker = File(_join(directory.path, _markerFileName));
    if (await marker.exists()) {
      if (!await _markerMatches(directory, spaceId)) {
        throw StateError('Space directory identity marker does not match');
      }
      return;
    }
    if (!allowNonEmpty &&
        (await directory.list(followLinks: false).isEmpty) == false) {
      throw StateError(
          'Space directory has no identity marker; refusing to adopt existing files');
    }
    final temporary = File(
        '${marker.path}.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}');
    await temporary.writeAsString(
        jsonEncode({
          'schemaVersion': _schemaVersion,
          'spaceId': spaceId,
          'displayName': spaceName.trim().isEmpty ? 'Space' : spaceName.trim(),
          'createdAt': DateTime.now().toUtc().toIso8601String(),
        }),
        flush: true);
    try {
      await temporary.rename(marker.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<Map<String, Map<String, Object?>>> _readRegistry() async {
    final file = File(_join(registryDirectory.path, _registryFileName));
    if (!await file.exists()) return <String, Map<String, Object?>>{};
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map || decoded['schemaVersion'] != _schemaVersion) {
        throw const FormatException('unsupported registry');
      }
      final entries = decoded['spaces'];
      if (entries is! Map) throw const FormatException('invalid registry');
      return entries.map((key, value) => MapEntry(
            key.toString(),
            value is Map
                ? Map<String, Object?>.from(value)
                : <String, Object?>{},
          ));
    } on FormatException catch (error) {
      throw StateError('Space directory registry is invalid: ${error.message}');
    } on FileSystemException catch (error) {
      throw StateError(
          'Space directory registry could not be read: ${error.message}');
    }
  }

  Future<void> _writeRegistry(Map<String, Map<String, Object?>> entries) async {
    final file = File(_join(registryDirectory.path, _registryFileName));
    final temporary =
        File('${file.path}.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}');
    await temporary.writeAsString(
        jsonEncode({
          'schemaVersion': _schemaVersion,
          'spaces': entries,
        }),
        flush: true);
    try {
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (_, __) {});
    return result;
  }

  String _relativeToRoot(String path) {
    final root = _canonical(workRoot.absolute.path);
    final value = _canonical(path);
    if (value == root) throw StateError('Space directory cannot be Work Root');
    final prefix = '$root${Platform.pathSeparator}';
    if (!value.startsWith(prefix)) {
      throw StateError('Space directory escaped Work Root');
    }
    return value.substring(prefix.length);
  }

  bool _isSafeRelativePath(String value) =>
      value.isNotEmpty &&
      !value.contains('/') &&
      !value.contains('\\') &&
      value != '.' &&
      value != '..';

  String _sanitizeName(String value) {
    var name = value.trim().replaceAll(RegExp(r'[\x00-\x1F<>:"/\\|?*]'), '-');
    name = name
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'[. ]+$'), '')
        .trim();
    if (name.isEmpty || name == '.' || name == '..') name = 'Space';
    if (RegExp(r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$', caseSensitive: false)
        .hasMatch(name)) {
      name = '$name Space';
    }
    return name.length > 120 ? name.substring(0, 120).trim() : name;
  }

  String _join(String parent, String child) =>
      '$parent${Platform.pathSeparator}$child';

  String _canonical(String path) => path.replaceAll(RegExp(r'[/\\]+$'), '');
}

class SpaceDirectoryLifecycle {
  const SpaceDirectoryLifecycle(this.resolver);

  final SpaceDirectoryResolver resolver;

  Future<Directory> ensureForExecution({
    required String spaceId,
    required String spaceName,
  }) =>
      resolver.resolve(spaceId: spaceId, spaceName: spaceName);
}

/// Serializes stateful work that shares one Space directory.
class SpaceMutationCoordinator {
  SpaceMutationCoordinator({
    required this.lifecycle,
    required this.applicationStateDirectory,
  });

  final SpaceDirectoryLifecycle lifecycle;
  final Directory applicationStateDirectory;
  final _tails = <String, Future<void>>{};

  Future<T> withMutation<T>({
    required String spaceId,
    required String spaceName,
    required String leaseId,
    required int fencingToken,
    required Future<T> Function(Directory directory) action,
  }) async {
    if (leaseId.trim().isEmpty || fencingToken <= 0) {
      throw const SpaceMutationViolation(
          'leaseId and positive fencingToken are required');
    }
    final previous = _tails[spaceId] ?? Future<void>.value();
    final gate = Completer<void>();
    _tails[spaceId] = gate.future;
    try {
      await previous.catchError((_) {});
      await applicationStateDirectory.create(recursive: true);
      final lockFile = File(_join(
          applicationStateDirectory.path, 'space-mutation-$spaceId.lock'));
      final handle = await lockFile.open(mode: FileMode.append);
      try {
        await handle.lock(FileLock.exclusive);
        final directory = await lifecycle.ensureForExecution(
            spaceId: spaceId, spaceName: spaceName);
        final fenceDirectory =
            Directory(_join(applicationStateDirectory.path, 'space-fences'));
        await fenceDirectory.create(recursive: true);
        final fenceFile = File(_join(fenceDirectory.path, '$spaceId.json'));
        Map<String, Object?>? previousFence;
        if (await fenceFile.exists()) {
          final value = jsonDecode(await fenceFile.readAsString());
          if (value is! Map) {
            throw const SpaceMutationViolation(
                'Space fencing metadata is invalid');
          }
          previousFence = Map<String, Object?>.from(value);
        }
        final priorToken = previousFence?['fencingToken'];
        final priorLease = previousFence?['leaseId'];
        if (previousFence != null &&
            (priorToken is! int ||
                priorLease is! String ||
                fencingToken < priorToken ||
                (fencingToken == priorToken && leaseId != priorLease))) {
          throw const SpaceMutationViolation(
              'stale or conflicting Space fencing token');
        }
        await fenceFile.writeAsString(
            jsonEncode({
              'leaseId': leaseId,
              'fencingToken': fencingToken,
              'updatedAt': DateTime.now().toUtc().toIso8601String(),
            }),
            flush: true);
        return await action(directory);
      } finally {
        await handle.unlock();
        await handle.close();
      }
    } finally {
      gate.complete();
      if (identical(_tails[spaceId], gate.future)) _tails.remove(spaceId);
    }
  }

  String _join(String parent, String child) =>
      '$parent${Platform.pathSeparator}$child';
}

class SpaceMutationViolation implements Exception {
  const SpaceMutationViolation(this.message);
  final String message;
  @override
  String toString() => 'SpaceMutationViolation: $message';
}
