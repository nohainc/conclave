import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A folder with the Space's name already exists, is not empty, and does not
/// belong to any Space. It is never used silently; the user must confirm.
class SpaceFolderExistsException implements Exception {
  const SpaceFolderExistsException(this.folderName);
  final String folderName;
  @override
  String toString() =>
      'SpaceFolderExistsException: "$folderName" already exists and is not empty';
}

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

  /// [adoptExistingFolder] is true only after the user confirmed that an
  /// existing, non-empty, unmarked folder may be used for this Space.
  Future<Directory> resolve({
    required String spaceId,
    required String spaceName,
    bool adoptExistingFolder = false,
  }) =>
      _serial(() => _resolve(
            spaceId: spaceId,
            spaceName: spaceName,
            adoptExistingFolder: adoptExistingFolder,
          ));

  Future<Directory> _resolve({
    required String spaceId,
    required String spaceName,
    required bool adoptExistingFolder,
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
        if (type == FileSystemEntityType.directory) {
          final existing = Directory(path);
          if (await _markerMatches(existing, spaceId)) {
            directory = existing;
            break;
          }
          // Never skip to "Name (2)" silently. A non-empty folder that is not
          // this Space's (unmarked, or marked for another Space, for example
          // one that was removed in the app) is the user's own: stop and ask,
          // then take it over once confirmed.
          if (!await existing.list(followLinks: false).isEmpty) {
            if (!adoptExistingFolder) {
              throw SpaceFolderExistsException(candidate);
            }
            final foreign = File(_join(path, _markerFileName));
            if (await foreign.exists()) await foreign.delete();
            registry.removeWhere((id, value) =>
                id != spaceId && value['relativePath'] == candidate);
            directory = existing;
            adoptingLegacy = true;
            break;
          }
          // Empty: safe to claim.
          if (await File(_join(path, _markerFileName)).exists()) {
            await File(_join(path, _markerFileName)).delete();
          }
          directory = existing;
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

  /// Forgets registry entries for Spaces that no longer exist in Cloud. Only
  /// the private registry changes; no Space folder or file is touched, and a
  /// folder that still carries its marker is simply re-discovered if needed.
  Future<int> forgetSpacesExcept(Set<String> knownSpaceIds) =>
      _serial(() async {
        final registry = await _readRegistry();
        final stale = registry.keys
            .where((id) => !knownSpaceIds.contains(id))
            .toList();
        if (stale.isEmpty) return 0;
        for (final id in stale) {
          registry.remove(id);
        }
        await registryDirectory.create(recursive: true);
        await _writeRegistry(registry);
        return stale.length;
      });

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

  Future<int> forgetSpacesExcept(Set<String> knownSpaceIds) =>
      resolver.forgetSpacesExcept(knownSpaceIds);

  Future<Directory> ensureForExecution({
    required String spaceId,
    required String spaceName,
    bool adoptExistingFolder = false,
  }) =>
      resolver.resolve(
        spaceId: spaceId,
        spaceName: spaceName,
        adoptExistingFolder: adoptExistingFolder,
      );
}

/// Serializes stateful work that shares one Space directory, while comparing
/// Cloud-issued fencing tokens only within the Thread that owns the lease.
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
    required String threadId,
    required String spaceName,
    required String leaseId,
    required int fencingToken,
    required Future<T> Function(Directory directory) action,
    bool adoptExistingFolder = false,
  }) async {
    if (!SpaceDirectoryResolver._safeId.hasMatch(spaceId) ||
        !SpaceDirectoryResolver._safeId.hasMatch(threadId)) {
      throw const SpaceMutationViolation('invalid Space or Thread identity');
    }
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
            spaceId: spaceId,
            spaceName: spaceName,
            adoptExistingFolder: adoptExistingFolder);
        // The process lock remains Space-wide because Threads share a CWD.
        // Lease counters are Thread-scoped in Cloud; a token from one Thread
        // cannot be ordered against a token from another Thread. Leave legacy
        // unscoped <spaceId>.json records intact as historical evidence.
        final fenceDirectory = Directory(_join(
            _join(applicationStateDirectory.path, 'space-fences'), spaceId));
        await fenceDirectory.create(recursive: true);
        final fenceFile = File(_join(fenceDirectory.path, '$threadId.json'));
        Map<String, Object?>? previousFence;
        if (await fenceFile.exists()) {
          final value = jsonDecode(await fenceFile.readAsString());
          if (value is! Map ||
              value['schemaVersion'] != 1 ||
              value['spaceId'] != spaceId ||
              value['threadId'] != threadId) {
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
              'schemaVersion': 1,
              'spaceId': spaceId,
              'threadId': threadId,
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
