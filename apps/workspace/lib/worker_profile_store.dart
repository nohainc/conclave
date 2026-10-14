import 'dart:convert';
import 'dart:io';

import 'package:conclave_tool_profile_v1/tool_profile_v1.dart';

import 'development_tool_profiles.dart';
import 'platform_runtime.dart';

/// The small persistence boundary used by the Workspace runtime.
///
/// Runtime code depends on this boundary rather than release/channel storage
/// APIs. Legacy on-disk snapshots are migrated by [WorkerProfileStore] itself.
abstract interface class WorkerProfileStorePort {
  Directory get profilesRoot;
  WorkerTrustPolicy get trustPolicy;
  DevelopmentToolProfiles? get developmentProfiles;

  Future<File> executionProfileFile(ToolProfileCandidate candidate);
  File stagedWorkerProfileFile(WorkerProfileSnapshotAdmission candidate);
  Future<bool> hasWorkerProfileCache(String workerTypeId);
  Future<WorkerProfileSnapshotAdmission> stageWorkerProfile(
    WorkerProfileSnapshotAdmission candidate,
  );
  Future<WorkerProfileSnapshotAdmission> activateWorkerProfile(
    WorkerProfileSnapshotAdmission candidate,
  );
  Future<WorkerProfileSnapshotAdmission?> currentWorkerProfile(
    String workerTypeId,
  );
  Future<WorkerProfileSnapshotAdmission?> lastKnownGoodWorkerProfile(
    String workerTypeId,
  );
  Future<void> restoreRevocations({bool force = false});
  Future<void> persistRevocations();
  Future<Set<String>> reconcileRevocations({String? profileDefinitionId});
}

/// Raised when the current V9 snapshot was explicitly revoked.
class WorkerProfileRevokedException implements Exception {
  const WorkerProfileRevokedException(this.workerTypeId);

  final String workerTypeId;

  @override
  String toString() => 'Worker Profile is revoked: $workerTypeId';
}

/// V9 local Profile cache.
///
/// Each Worker owns one current verified snapshot, one last-known-good
/// snapshot, and an optional staging snapshot. Immutable revision files are
/// retained so an execution can keep using its selected digest after a later
/// refresh activates a newer Profile.
class WorkerProfileStore implements WorkerProfileStorePort {
  WorkerProfileStore({
    required this.profilesRoot,
    required this.trustPolicy,
    PlatformRuntime? fileSystemPlatform,
    this.developmentProfiles,
  }) : fileSystemPlatform = fileSystemPlatform ?? currentPlatformRuntime;

  static const maxTrustStateBytes = 2 * 1024 * 1024;
  static const maxLegacyDefinitions = 128;

  @override
  final Directory profilesRoot;
  @override
  final WorkerTrustPolicy trustPolicy;
  @override
  final DevelopmentToolProfiles? developmentProfiles;
  final PlatformRuntime fileSystemPlatform;
  bool _revocationSnapshotRestored = false;
  bool _legacyMigrationAttempted = false;

  Directory workerProfileDirectory(String workerTypeId) => Directory(
        '${profilesRoot.path}${Platform.pathSeparator}v9-workers'
        '${Platform.pathSeparator}${_safeId(workerTypeId)}',
      );

  File workerProfileFile(WorkerProfileSnapshotAdmission candidate) => File(
        '${workerProfileDirectory(candidate.workerTypeId).path}'
        '${Platform.pathSeparator}current-profile.json',
      );

  @override
  File stagedWorkerProfileFile(WorkerProfileSnapshotAdmission candidate) =>
      _stagingPayloadFile(candidate.workerTypeId);

  File _snapshotFile(String workerTypeId, {bool lastKnownGood = false}) => File(
      '${workerProfileDirectory(workerTypeId).path}'
      '${Platform.pathSeparator}${lastKnownGood ? 'last-known-good' : 'current'}.json');

  File _payloadFile(String workerTypeId, {bool lastKnownGood = false}) => File(
      '${workerProfileDirectory(workerTypeId).path}'
      '${Platform.pathSeparator}${lastKnownGood ? 'last-known-good' : 'current'}-profile.json');

  File _stagingFile(String workerTypeId) =>
      File('${workerProfileDirectory(workerTypeId).path}'
          '${Platform.pathSeparator}staging.json');

  File _stagingPayloadFile(String workerTypeId) =>
      File('${workerProfileDirectory(workerTypeId).path}'
          '${Platform.pathSeparator}staging-profile.json');

  File _executionFile(
    String workerTypeId,
    int revision,
    String digest,
  ) =>
      File('${workerProfileDirectory(workerTypeId).path}'
          '${Platform.pathSeparator}revisions${Platform.pathSeparator}'
          '$revision-$digest.json');

  File _trustStateFile() =>
      File('${profilesRoot.path}${Platform.pathSeparator}trust-state.json');

  @override
  Future<File> executionProfileFile(ToolProfileCandidate candidate) async {
    if (!candidate.isPublished) {
      final development = developmentProfiles;
      if (development == null) {
        throw StateError('Unpublished Profile execution is disabled');
      }
      return development.snapshot(candidate);
    }
    if (candidate is! WorkerProfileSnapshotAdmission) {
      throw StateError('Workspace requires a V9 Worker Profile snapshot');
    }
    await _ensureLegacyMigration();
    final file = _executionFile(
      candidate.workerTypeId,
      candidate.revision,
      candidate.payloadDigest,
    );
    if (await file.exists()) return file;
    await _withLock(() async {
      if (await file.exists()) return;
      await _writeImmutablePayload(file, candidate.profile);
    });
    return file;
  }

  @override
  Future<bool> hasWorkerProfileCache(String workerTypeId) async {
    await _ensureLegacyMigration();
    return await _snapshotFile(workerTypeId).exists() ||
        await _snapshotFile(workerTypeId, lastKnownGood: true).exists() ||
        await _stagingFile(workerTypeId).exists();
  }

  @override
  Future<WorkerProfileSnapshotAdmission> stageWorkerProfile(
    WorkerProfileSnapshotAdmission candidate,
  ) async {
    await restoreRevocations();
    await _ensureLegacyMigration();
    final snapshot = await _verifiedSnapshot(candidate);
    await _withLock(() async {
      final directory = workerProfileDirectory(candidate.workerTypeId);
      await directory.create(recursive: true);
      await fileSystemPlatform.restrictPermissions(directory.path,
          directory: true);
      await _atomicWrite(
          _stagingFile(candidate.workerTypeId), canonicalJson(snapshot));
      await _atomicWrite(_stagingPayloadFile(candidate.workerTypeId),
          canonicalJson(candidate.profile));
      await _writeImmutablePayload(
        _executionFile(
          candidate.workerTypeId,
          candidate.revision,
          candidate.payloadDigest,
        ),
        candidate.profile,
      );
    });
    return candidate;
  }

  @override
  Future<WorkerProfileSnapshotAdmission> activateWorkerProfile(
    WorkerProfileSnapshotAdmission candidate,
  ) async {
    await restoreRevocations();
    await _ensureLegacyMigration();
    WorkerProfileSnapshotAdmission? activated;
    await _withLock(() async {
      final staged = await _readSnapshot(candidate.workerTypeId, staging: true);
      if (staged == null ||
          staged.revision != candidate.revision ||
          staged.payloadDigest != candidate.payloadDigest) {
        throw StateError('V9 Worker Profile staging identity changed');
      }
      final current = await _readSnapshot(
        candidate.workerTypeId,
        allowRevokedCurrent: true,
      );
      if (current != null && current.revision != staged.revision) {
        await _copyFile(
          _snapshotFile(candidate.workerTypeId),
          _snapshotFile(candidate.workerTypeId, lastKnownGood: true),
        );
        await _copyFile(
          _payloadFile(candidate.workerTypeId),
          _payloadFile(candidate.workerTypeId, lastKnownGood: true),
        );
      }
      // Replacing the metadata pointer is the activation boundary. Readers
      // either see the old complete snapshot or the new complete snapshot.
      await _replaceFile(
        _stagingFile(candidate.workerTypeId),
        _snapshotFile(candidate.workerTypeId),
      );
      await _copyFile(
        _stagingPayloadFile(candidate.workerTypeId),
        _payloadFile(candidate.workerTypeId),
      );
      final stagingPayload = _stagingPayloadFile(candidate.workerTypeId);
      if (await stagingPayload.exists()) await stagingPayload.delete();
      activated = await _readSnapshot(candidate.workerTypeId);
      if (activated == null) {
        throw StateError('V9 Worker Profile activation did not persist');
      }
    });
    return activated!;
  }

  @override
  Future<WorkerProfileSnapshotAdmission?> currentWorkerProfile(
    String workerTypeId,
  ) async {
    await _ensureLegacyMigration();
    return _readSnapshot(workerTypeId);
  }

  @override
  Future<WorkerProfileSnapshotAdmission?> lastKnownGoodWorkerProfile(
    String workerTypeId,
  ) async {
    await _ensureLegacyMigration();
    return _readSnapshot(workerTypeId, lastKnownGood: true);
  }

  /// Atomically promotes the verified LKG snapshot after an optional probe.
  /// The identity is rechecked while holding the cache lock.
  Future<WorkerProfileSnapshotAdmission> restoreLastKnownGood(
    String workerTypeId, {
    Future<bool> Function(WorkerProfileSnapshotAdmission candidate)? validator,
  }) async {
    await _ensureLegacyMigration();
    final candidate = await lastKnownGoodWorkerProfile(workerTypeId);
    if (candidate == null) {
      throw StateError('Worker Profile has no last-known-good snapshot');
    }
    if (validator != null && !await validator(candidate)) {
      throw StateError(
          'Last-known-good Worker Profile did not pass validation');
    }
    WorkerProfileSnapshotAdmission? restored;
    await _withLock(() async {
      final currentLkg = await _readSnapshot(workerTypeId, lastKnownGood: true);
      if (currentLkg?.revision != candidate.revision ||
          currentLkg?.payloadDigest != candidate.payloadDigest) {
        throw StateError(
            'Last-known-good Worker Profile changed during restore');
      }
      final current = await _readSnapshot(workerTypeId);
      // Preserve the selected LKG before replacing it with the current
      // snapshot. Copying current into the LKG slot first would otherwise
      // overwrite the snapshot being restored.
      await _copyFile(
        _snapshotFile(workerTypeId, lastKnownGood: true),
        _stagingFile(workerTypeId),
      );
      await _copyFile(
        _payloadFile(workerTypeId, lastKnownGood: true),
        _stagingPayloadFile(workerTypeId),
      );
      if (current != null && current.revision != candidate.revision) {
        await _copyFile(_snapshotFile(workerTypeId),
            _snapshotFile(workerTypeId, lastKnownGood: true));
        await _copyFile(_payloadFile(workerTypeId),
            _payloadFile(workerTypeId, lastKnownGood: true));
      }
      await _replaceFile(
          _stagingFile(workerTypeId), _snapshotFile(workerTypeId));
      await _copyFile(
          _stagingPayloadFile(workerTypeId), _payloadFile(workerTypeId));
      final stagingPayload = _stagingPayloadFile(workerTypeId);
      if (await stagingPayload.exists()) await stagingPayload.delete();
      restored = await _readSnapshot(workerTypeId);
    });
    return restored!;
  }

  @override
  Future<void> restoreRevocations({bool force = false}) async {
    if (_revocationSnapshotRestored && !force) return;
    final file = _trustStateFile();
    final type = FileSystemEntity.typeSync(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      _revocationSnapshotRestored = true;
      return;
    }
    if (type != FileSystemEntityType.file ||
        file.lengthSync() < 1 ||
        file.lengthSync() > maxTrustStateBytes) {
      throw const FormatException('Profile trust state is invalid');
    }
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map || decoded['schemaVersion'] != 1) {
      throw const FormatException('Profile trust state is invalid');
    }
    Set<String> readSet(String key) {
      final values = decoded[key];
      if (values is! List ||
          values.length > 10000 ||
          values.any((value) => value is! String)) {
        throw FormatException('Profile trust state $key is invalid');
      }
      return values.cast<String>().toSet();
    }

    trustPolicy.updateRevocations(
      digests: {...trustPolicy.revokedDigests, ...readSet('digests')},
      publishers: {...trustPolicy.revokedPublishers, ...readSet('publishers')},
      keyIds: {...trustPolicy.revokedKeyIds, ...readSet('keyIds')},
      releaseIds: {...trustPolicy.revokedReleaseIds, ...readSet('releaseIds')},
    );
    _revocationSnapshotRestored = true;
  }

  @override
  Future<void> persistRevocations() async {
    await _withLock(() async {
      await _atomicWrite(
        _trustStateFile(),
        canonicalJson({
          'schemaVersion': 1,
          'digests': trustPolicy.revokedDigests.toList()..sort(),
          'publishers': trustPolicy.revokedPublishers.toList()..sort(),
          'keyIds': trustPolicy.revokedKeyIds.toList()..sort(),
          'releaseIds': trustPolicy.revokedReleaseIds.toList()..sort(),
        }),
      );
      _revocationSnapshotRestored = true;
    });
  }

  @override
  Future<Set<String>> reconcileRevocations(
      {String? profileDefinitionId}) async {
    await restoreRevocations();
    final affected = <String>{};
    final root =
        Directory('${profilesRoot.path}${Platform.pathSeparator}v9-workers');
    if (!await root.exists()) return affected;
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final workerTypeId = entity.path.split(Platform.pathSeparator).last;
      try {
        await _readSnapshot(workerTypeId);
      } on WorkerProfileRevokedException {
        affected.add(workerTypeId);
      } on Object {
        // A malformed cache is not activated; Cloud refresh repairs it.
      }
    }
    return affected;
  }

  Future<Map<String, Object?>> _verifiedSnapshot(
    WorkerProfileSnapshotAdmission candidate,
  ) async {
    final schemaVersion = candidate.profile['schemaVersion'];
    if (schemaVersion is! int) {
      throw const FormatException('Worker Profile schema version is invalid');
    }
    final snapshot = <String, Object?>{
      'workerTypeId': candidate.workerTypeId,
      'schemaVersion': schemaVersion,
      'profile': candidate.profile,
      'revision': candidate.revision,
      'digest': candidate.payloadDigest,
    };
    await WorkerProfileSnapshotVerifier.verify(
      input: snapshot,
      expectedWorkerTypeId: candidate.workerTypeId,
    );
    return snapshot;
  }

  Future<WorkerProfileSnapshotAdmission?> _readSnapshot(
    String workerTypeId, {
    bool lastKnownGood = false,
    bool staging = false,
    bool allowRevokedCurrent = false,
  }) async {
    await restoreRevocations();
    final file = staging
        ? _stagingFile(workerTypeId)
        : _snapshotFile(workerTypeId, lastKnownGood: lastKnownGood);
    final payload = staging
        ? _stagingPayloadFile(workerTypeId)
        : _payloadFile(workerTypeId, lastKnownGood: lastKnownGood);
    final fileType = FileSystemEntity.typeSync(file.path, followLinks: false);
    if (fileType == FileSystemEntityType.notFound) return null;
    if (fileType != FileSystemEntityType.file ||
        file.lengthSync() > WorkerProfileSnapshotVerifier.maxSnapshotBytes) {
      throw const FormatException('V9 Worker Profile cache is invalid');
    }
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map) {
      throw const FormatException('V9 Worker Profile cache is invalid');
    }
    final snapshot = Map<String, Object?>.from(decoded);
    final revision = snapshot['revision'];
    final digest = snapshot['digest'];
    if (revision is int &&
        digest is String &&
        trustPolicy.revokedDigests.contains(digest)) {
      if (!lastKnownGood && !staging && !allowRevokedCurrent) {
        throw WorkerProfileRevokedException(workerTypeId);
      }
      return null;
    }
    final verified = await WorkerProfileSnapshotVerifier.verify(
      input: snapshot,
      expectedWorkerTypeId: workerTypeId,
    );
    if (await payload.exists()) {
      final payloadValue = jsonDecode(await payload.readAsString());
      if (canonicalJson(payloadValue) != canonicalJson(verified.profile)) {
        throw const FormatException('V9 Worker Profile payload has changed');
      }
    } else if (!staging) {
      // The verified snapshot is authoritative; repair the derived payload.
      await _writeImmutablePayload(payload, verified.profile);
    }
    return verified;
  }

  Future<void> _ensureLegacyMigration() async {
    if (_legacyMigrationAttempted) return;
    _legacyMigrationAttempted = true;
    await restoreRevocations();
    await _withLock(() async {
      if (!await profilesRoot.exists()) return;
      final entries = <Directory>[];
      await for (final entity in profilesRoot.list(followLinks: false)) {
        if (entity is Directory &&
            entity.path.split(Platform.pathSeparator).last != 'v9-workers') {
          entries.add(entity);
        }
      }
      if (entries.length > maxLegacyDefinitions) return;
      for (final definition in entries) {
        await _migrateLegacyDefinition(definition);
      }
    });
  }

  Future<void> _migrateLegacyDefinition(Directory definition) async {
    final stateFile =
        File('${definition.path}${Platform.pathSeparator}release-state.json');
    if (!await stateFile.exists()) return;
    try {
      final state = jsonDecode(await stateFile.readAsString());
      if (state is! Map) return;
      final version = state['stableVersion'] is int
          ? state['stableVersion'] as int
          : state['activeVersion'];
      if (version is! int || version < 1) return;
      final releaseFile =
          File('${definition.path}${Platform.pathSeparator}$version'
              '${Platform.pathSeparator}release.json');
      if (!await releaseFile.exists()) return;
      final release = jsonDecode(await releaseFile.readAsString());
      if (release is! Map || release['workerTypeId'] is! String) return;
      final workerTypeId = release['workerTypeId'] as String;
      final admission = await ToolProfileReleaseVerifier.verify(
        input: release,
        expectedWorkerTypeId: workerTypeId,
      );
      final snapshot = <String, Object?>{
        'workerTypeId': workerTypeId,
        'schemaVersion': admission.profile['schemaVersion'],
        'profile': admission.profile,
        'revision': admission.revision,
        'digest': admission.payloadDigest,
      };
      await WorkerProfileSnapshotVerifier.verify(
        input: snapshot,
        expectedWorkerTypeId: workerTypeId,
      );
      final directory = workerProfileDirectory(workerTypeId);
      await directory.create(recursive: true);
      await _atomicWrite(_snapshotFile(workerTypeId), canonicalJson(snapshot));
      await _atomicWrite(
          _payloadFile(workerTypeId), canonicalJson(admission.profile));
      await _writeImmutablePayload(
        _executionFile(
            workerTypeId, admission.revision, admission.payloadDigest),
        admission.profile,
      );
      await definition.delete(recursive: true);
    } on Object {
      // Keep an un-migratable legacy cache intact. It remains recoverable by
      // a later Cloud sync, while no unverified data enters the V9 cache.
    }
  }

  Future<void> _writeImmutablePayload(
      File file, Map<String, Object?> profile) async {
    if (await file.exists()) return;
    await _atomicWrite(file, canonicalJson(profile));
  }

  Future<void> _copyFile(File source, File target) async {
    if (await FileSystemEntity.type(source.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw StateError('V9 Worker Profile source file is missing');
    }
    await _atomicWrite(target, await source.readAsString());
  }

  Future<void> _replaceFile(File source, File target) async {
    final sourceType =
        await FileSystemEntity.type(source.path, followLinks: false);
    if (sourceType != FileSystemEntityType.file) {
      throw StateError('V9 Worker Profile staging file is missing');
    }
    final targetType =
        await FileSystemEntity.type(target.path, followLinks: false);
    if (targetType != FileSystemEntityType.notFound &&
        targetType != FileSystemEntityType.file) {
      throw StateError('V9 Worker Profile target path is unsafe');
    }
    await source.rename(target.path);
  }

  Future<void> _atomicWrite(File target, String contents) async {
    await target.parent.create(recursive: true);
    final type = await FileSystemEntity.type(target.path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      throw StateError('V9 Worker Profile target path is unsafe');
    }
    final temporary = File(
        '${target.path}.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}');
    await temporary.writeAsString(contents, flush: true);
    await fileSystemPlatform.restrictPermissions(temporary.path,
        directory: false);
    await temporary.rename(target.path);
    await fileSystemPlatform.restrictPermissions(target.parent.path,
        directory: true);
  }

  Future<T> _withLock<T>(Future<T> Function() action) async {
    await profilesRoot.create(recursive: true);
    await fileSystemPlatform.restrictPermissions(profilesRoot.path,
        directory: true);
    final lockFile =
        File('${profilesRoot.path}${Platform.pathSeparator}.profiles.lock');
    final handle = await lockFile.open(mode: FileMode.append);
    try {
      await fileSystemPlatform.restrictPermissions(lockFile.path,
          directory: false);
      await handle.lock(FileLock.exclusive);
      return await action();
    } finally {
      await handle.unlock();
      await handle.close();
    }
  }
}

String _safeId(String value) {
  if (!RegExp(r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$').hasMatch(value) ||
      value.length > 96) {
    throw FormatException('Worker Profile ID is invalid');
  }
  return value;
}
