import 'dart:convert';
import 'dart:io';

import 'package:conclave_tool_profile_v1/tool_profile_v1.dart';

import 'platform_runtime.dart';

export 'package:conclave_tool_profile_v1/tool_profile_v1.dart'
    show canonicalJson;

class ToolProfileReleaseState {
  const ToolProfileReleaseState({
    required this.activeVersion,
    required this.lastKnownGoodVersion,
    required this.stableVersion,
    required this.selectedChannel,
  });

  final int? activeVersion;
  final int? lastKnownGoodVersion;
  final int? stableVersion;
  final String selectedChannel;
}

/// Owns verified, immutable Profile material independently of Engine binaries.
class ToolProfileReleaseStore {
  ToolProfileReleaseStore({
    required this.profilesRoot,
    required this.trustPolicy,
    PlatformRuntime? fileSystemPlatform,
    this.retentionLimit = 3,
  }) : fileSystemPlatform = fileSystemPlatform ?? currentPlatformRuntime {
    if (retentionLimit < 2 || retentionLimit > 32) {
      throw ArgumentError.value(
        retentionLimit,
        'retentionLimit',
        'must be between 2 and 32',
      );
    }
  }

  static const maxReleaseMetadataBytes = 512 * 1024;
  static const maxTrustStateBytes = 2 * 1024 * 1024;
  static const maxDefinitions = 128;
  static const maxCachedReleases = 512;

  final Directory profilesRoot;
  final WorkerTrustPolicy trustPolicy;
  final PlatformRuntime fileSystemPlatform;
  final int retentionLimit;
  bool _revocationSnapshotRestored = false;

  Directory definitionDirectory(String profileDefinitionId) => Directory(
        '${profilesRoot.path}${Platform.pathSeparator}'
        '${_safeDefinitionId(profileDefinitionId)}',
      );

  Directory releaseDirectory(String profileDefinitionId, int releaseVersion) =>
      Directory(
        '${definitionDirectory(profileDefinitionId).path}'
        '${Platform.pathSeparator}${_safeVersion(releaseVersion)}',
      );

  File profileFile(String profileDefinitionId, int releaseVersion) => File(
        '${releaseDirectory(profileDefinitionId, releaseVersion).path}'
        '${Platform.pathSeparator}profile.json',
      );

  File _releaseMetadataFile(String profileDefinitionId, int releaseVersion) =>
      File(
        '${releaseDirectory(profileDefinitionId, releaseVersion).path}'
        '${Platform.pathSeparator}release.json',
      );

  File _releaseStateFile(String profileDefinitionId) => File(
        '${definitionDirectory(profileDefinitionId).path}'
        '${Platform.pathSeparator}release-state.json',
      );

  File _trustStateFile() =>
      File('${profilesRoot.path}${Platform.pathSeparator}trust-state.json');

  /// Verifies the Cloud release before materializing immutable local files.
  /// Releases are staged by default; activation must follow candidate checks.
  Future<ToolProfileReleaseAdmission> installRelease({
    required Object? releaseInput,
    required String expectedWorkerTypeId,
  }) async {
    await restoreRevocations();
    final admission = await ToolProfileReleaseVerifier.verify(
      input: releaseInput,
      trustPolicy: trustPolicy,
      expectedWorkerTypeId: expectedWorkerTypeId,
    );
    final release = Map<String, Object?>.from(releaseInput! as Map);
    final definitionId = _safeDefinitionId(admission.profileDefinitionId);
    final version = _safeVersion(admission.releaseVersion);
    await _withLock(() async {
      final definition = definitionDirectory(definitionId);
      final definitionType = await FileSystemEntity.type(
        definition.path,
        followLinks: false,
      );
      if (definitionType == FileSystemEntityType.link ||
          (definitionType != FileSystemEntityType.notFound &&
              definitionType != FileSystemEntityType.directory)) {
        throw StateError('Tool Profile definition path is unsafe');
      }
      if (definitionType == FileSystemEntityType.notFound &&
          (await _definitionIds()).length >= maxDefinitions) {
        throw StateError('Workspace Profile cache has too many definitions');
      }
      await definition.create(recursive: true);
      await fileSystemPlatform.restrictPermissions(definition.path,
          directory: true);
      final target = releaseDirectory(definitionId, version);
      if (await FileSystemEntity.type(target.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        await _verifyInstalled(definitionId, version);
        final existing =
            await _releaseMetadataFile(definitionId, version).readAsString();
        if (jsonDecode(existing) case final Map decoded) {
          if (decoded['payloadDigest'] != admission.payloadDigest ||
              decoded['signature'] != release['signature']) {
            throw StateError('Installed Profile release is immutable');
          }
        }
        // Lifecycle metadata may change on promotion while signed behavior
        // and the release identity remain immutable.
        await _atomicWrite(_releaseMetadataFile(definitionId, version),
            canonicalJson(release));
      } else {
        if (await _cachedReleaseCount() >= maxCachedReleases) {
          throw StateError('Workspace Profile cache is full');
        }
        final staging = Directory(
          '${definition.path}${Platform.pathSeparator}'
          '.staging-$version-$pid-${DateTime.now().microsecondsSinceEpoch}',
        );
        await staging.create();
        try {
          final profile = File(
            '${staging.path}${Platform.pathSeparator}profile.json',
          );
          final metadata = File(
            '${staging.path}${Platform.pathSeparator}release.json',
          );
          await profile.writeAsString(canonicalJson(admission.profile),
              flush: true);
          await metadata.writeAsString(canonicalJson(release), flush: true);
          await fileSystemPlatform.restrictPermissions(profile.path,
              directory: false);
          await fileSystemPlatform.restrictPermissions(metadata.path,
              directory: false);
          await fileSystemPlatform.restrictPermissions(staging.path,
              directory: true);
          await staging.rename(target.path);
        } catch (_) {
          if (await staging.exists()) await staging.delete(recursive: true);
          rethrow;
        }
      }
    });
    return admission;
  }

  Future<ToolProfileReleaseAdmission> activateVersion(
    String profileDefinitionId,
    int releaseVersion, {
    bool selectAsStable = false,
  }) async {
    await restoreRevocations();
    final definitionId = _safeDefinitionId(profileDefinitionId);
    final version = _safeVersion(releaseVersion);
    ToolProfileReleaseAdmission? admission;
    await _withLock(() async {
      admission = await _verifyInstalled(definitionId, version);
      final current = await _readState(definitionId);
      final previousActive = current?['activeVersion'];
      await _writeState(definitionId, {
        'schemaVersion': 1,
        'activeVersion': version,
        'selectedChannel': admission!.channel,
        if (selectAsStable && admission!.channel == 'stable')
          'stableVersion': version,
        if ((!selectAsStable || admission!.channel != 'stable') &&
            current?['stableVersion'] is int)
          'stableVersion': current!['stableVersion'],
        if (previousActive is int && previousActive != version)
          'lastKnownGoodVersion': previousActive,
        if (previousActive == version &&
            current?['lastKnownGoodVersion'] is int)
          'lastKnownGoodVersion': current!['lastKnownGoodVersion'],
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      });
      await _enforceRetention(definitionId);
    });
    return admission!;
  }

  Future<void> enforceRetention({String? profileDefinitionId}) async {
    await _withLock(() async {
      final definitions = profileDefinitionId == null
          ? await _definitionIds()
          : [_safeDefinitionId(profileDefinitionId)];
      for (final definitionId in definitions) {
        await _enforceRetention(definitionId);
      }
    });
  }

  Future<ToolProfileReleaseAdmission> rollbackToLastKnownGood(
    String profileDefinitionId, {
    required Future<bool> Function(ToolProfileReleaseAdmission candidate)
        candidateValidator,
  }) async {
    await restoreRevocations();
    final definitionId = _safeDefinitionId(profileDefinitionId);
    final candidate = await lastKnownGoodRelease(definitionId);
    if (candidate == null) {
      throw StateError('Tool Profile has no last-known-good release');
    }
    if (!await candidateValidator(candidate)) {
      throw StateError('Last-known-good Tool Profile did not pass validation');
    }
    ToolProfileReleaseAdmission? activated;
    await _withLock(() async {
      final current = await _readState(definitionId);
      if (current?['lastKnownGoodVersion'] != candidate.releaseVersion) {
        throw StateError('Last-known-good Tool Profile changed during probe');
      }
      activated =
          await _verifyInstalled(definitionId, candidate.releaseVersion);
      final previousActive = current?['activeVersion'];
      await _writeState(definitionId, {
        'schemaVersion': 1,
        'activeVersion': candidate.releaseVersion,
        if (current?['stableVersion'] is int)
          'stableVersion': current!['stableVersion'],
        if (previousActive is int && previousActive != candidate.releaseVersion)
          'lastKnownGoodVersion': previousActive,
        if (previousActive == candidate.releaseVersion &&
            current?['lastKnownGoodVersion'] is int)
          'lastKnownGoodVersion': current!['lastKnownGoodVersion'],
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      });
      await _enforceRetention(definitionId);
    });
    return activated!;
  }

  Future<ToolProfileReleaseState> releaseState(
    String profileDefinitionId,
  ) async {
    final state = await _readState(_safeDefinitionId(profileDefinitionId));
    return ToolProfileReleaseState(
      activeVersion: state?['activeVersion'] as int?,
      lastKnownGoodVersion: state?['lastKnownGoodVersion'] as int?,
      stableVersion: state?['stableVersion'] as int?,
      selectedChannel: state?['selectedChannel'] as String? ?? 'stable',
    );
  }

  /// Mirrors the Cloud-selected channel and validated release selection.
  Future<void> applyCatalogSelection({
    required String workerTypeId,
    required Map<String, int> selectedVersionsByDefinition,
    required String selectedChannel,
    Set<String> preserveDefinitionIds = const {},
  }) async {
    if (!const {'testing', 'beta', 'stable'}.contains(selectedChannel)) {
      throw ArgumentError.value(selectedChannel, 'selectedChannel');
    }
    await _withLock(() async {
      for (final definitionId in await _definitionIds()) {
        final state = await _readState(definitionId);
        if (state == null) continue;
        var active = state['activeVersion'] as int?;
        var lkg = state['lastKnownGoodVersion'] as int?;
        var stable = state['stableVersion'] as int?;
        final previousChannel = state['selectedChannel'] as String? ?? 'stable';
        final activeChannel = selectedChannel;
        final selectedVersion = selectedVersionsByDefinition[definitionId];
        if (preserveDefinitionIds.contains(definitionId)) {
          continue;
        }
        if (selectedVersion != null) {
          if (!await _belongsToWorker(
              definitionId, selectedVersion, workerTypeId)) {
            throw StateError('Selected Profile does not belong to Worker');
          }
          active = selectedVersion;
          if (selectedChannel == 'stable') stable = selectedVersion;
        } else if (selectedChannel == 'stable') {
          if (stable != null &&
              await _belongsToWorker(definitionId, stable, workerTypeId)) {
            stable = null;
          }
          if (active != null &&
              await _belongsToWorker(definitionId, active, workerTypeId)) {
            active = null;
          }
          if (lkg != null &&
              await _belongsToWorker(definitionId, lkg, workerTypeId)) {
            lkg = null;
          }
        }
        if (selectedChannel != 'stable' &&
            active != null &&
            await _belongsToWorker(definitionId, active, workerTypeId)) {
          try {
            final activeRelease = await _verifyInstalled(definitionId, active);
            if (activeRelease.channel != selectedChannel) active = null;
          } on Object {
            active = null;
          }
        }
        if (active != state['activeVersion'] ||
            lkg != state['lastKnownGoodVersion'] ||
            stable != state['stableVersion'] ||
            activeChannel != previousChannel) {
          await _writeState(definitionId, {
            'schemaVersion': 1,
            if (active != null) 'activeVersion': active,
            if (lkg != null) 'lastKnownGoodVersion': lkg,
            if (stable != null) 'stableVersion': stable,
            'selectedChannel': selectedChannel,
            'updatedAt': DateTime.now().toUtc().toIso8601String(),
          });
        }
      }
    });
  }

  Future<ToolProfileReleaseAdmission?> currentStableRelease(
    String profileDefinitionId,
  ) =>
      _pointedRelease(profileDefinitionId, 'stableVersion');

  Future<ToolProfileReleaseAdmission?> lastKnownGoodRelease(
    String profileDefinitionId,
  ) =>
      _pointedRelease(profileDefinitionId, 'lastKnownGoodVersion');

  Future<ToolProfileReleaseAdmission?> _pointedRelease(
    String profileDefinitionId,
    String pointer,
  ) async {
    await restoreRevocations();
    final definitionId = _safeDefinitionId(profileDefinitionId);
    final state = await _readState(definitionId);
    final version = state?[pointer];
    if (version is! int) return null;
    try {
      return await _verifyInstalled(definitionId, version);
    } on Object {
      await reconcileRevocations(profileDefinitionId: definitionId);
      return null;
    }
  }

  Future<ToolProfileReleaseAdmission?> activeRelease(
    String profileDefinitionId,
  ) async {
    await restoreRevocations();
    final definitionId = _safeDefinitionId(profileDefinitionId);
    final state = await _readState(definitionId);
    final version = state?['activeVersion'];
    if (version is! int) return null;
    try {
      return await _verifyInstalled(definitionId, version);
    } on Object {
      await reconcileRevocations(profileDefinitionId: definitionId);
      return null;
    }
  }

  Future<List<int>> installedVersions(String profileDefinitionId) async {
    final definitionId = _safeDefinitionId(profileDefinitionId);
    final definition = definitionDirectory(definitionId);
    final definitionType = await FileSystemEntity.type(
      definition.path,
      followLinks: false,
    );
    if (definitionType == FileSystemEntityType.notFound) return const [];
    if (definitionType != FileSystemEntityType.directory) {
      throw StateError('Tool Profile definition path is unsafe');
    }
    final versions = <int>[];
    await for (final entity in definition.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = entity.path.split(Platform.pathSeparator).last;
      final version = int.tryParse(name);
      if (version == null || version < 1 || version > 0x7fffffff) continue;
      if (await FileSystemEntity.type(entity.path, followLinks: false) ==
          FileSystemEntityType.directory) {
        versions.add(version);
      }
    }
    versions.sort((left, right) => right.compareTo(left));
    return List.unmodifiable(versions);
  }

  /// Loads a bounded revocation snapshot saved by the most recent Cloud sync.
  Future<void> restoreRevocations({bool force = false}) async {
    if (_revocationSnapshotRestored && !force) return;
    final file = _trustStateFile();
    final fileType = FileSystemEntity.typeSync(file.path, followLinks: false);
    if (fileType == FileSystemEntityType.notFound) {
      _revocationSnapshotRestored = true;
      return;
    }
    if (fileType != FileSystemEntityType.file) {
      throw const FormatException('Profile trust state path is unsafe');
    }
    final length = file.lengthSync();
    if (length < 1 || length > maxTrustStateBytes) {
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
          values.any((v) => v is! String)) {
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

  Future<void> persistRevocations() async {
    await _withLock(() async {
      await profilesRoot.create(recursive: true);
      final file = _trustStateFile();
      await _atomicWrite(
          file,
          canonicalJson({
            'schemaVersion': 1,
            'digests': trustPolicy.revokedDigests.toList()..sort(),
            'publishers': trustPolicy.revokedPublishers.toList()..sort(),
            'keyIds': trustPolicy.revokedKeyIds.toList()..sort(),
            'releaseIds': trustPolicy.revokedReleaseIds.toList()..sort(),
          }));
      _revocationSnapshotRestored = true;
    });
  }

  /// Removes revoked or corrupted releases and repairs pointers to verified
  /// cached versions. Releases from an unknown key remain cached but inactive.
  Future<Set<String>> reconcileRevocations(
      {String? profileDefinitionId}) async {
    await restoreRevocations();
    final affectedWorkerTypeIds = <String>{};
    await _withLock(() async {
      final definitions = profileDefinitionId == null
          ? await _definitionIds()
          : [_safeDefinitionId(profileDefinitionId)];
      for (final definitionId in definitions) {
        final versions = await installedVersions(definitionId);
        final state = await _readState(definitionId);
        final previousActive = state?['activeVersion'];
        final valid = <int>[];
        for (final version in versions) {
          try {
            await _verifyInstalled(definitionId, version);
            valid.add(version);
          } on Object {
            if (version == previousActive) {
              final workerTypeId =
                  await _releaseWorkerTypeId(definitionId, version);
              if (workerTypeId != null) {
                affectedWorkerTypeIds.add(workerTypeId);
              }
            }
            if (await _shouldDiscardInvalidRelease(definitionId, version)) {
              final directory = releaseDirectory(definitionId, version);
              if (await directory.exists()) {
                await directory.delete(recursive: true);
              }
            }
          }
        }
        if (state == null) continue;
        final active = valid.contains(previousActive) ? previousActive : null;
        final previousLkg = state['lastKnownGoodVersion'];
        final lkg = valid.contains(previousLkg) && previousLkg != active
            ? previousLkg
            : null;
        await _writeState(definitionId, {
          'schemaVersion': 1,
          'selectedChannel': state['selectedChannel'] ?? 'stable',
          if (active is int) 'activeVersion': active,
          if (lkg is int) 'lastKnownGoodVersion': lkg,
          if (valid.contains(state['stableVersion']))
            'stableVersion': state['stableVersion'],
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
        });
        await _enforceRetention(definitionId);
      }
    });
    return Set.unmodifiable(affectedWorkerTypeIds);
  }

  Future<String?> _releaseWorkerTypeId(String definitionId, int version) async {
    try {
      final file = _releaseMetadataFile(definitionId, version);
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return null;
      }
      if (await file.length() > maxReleaseMetadataBytes) return null;
      final decoded = jsonDecode(await file.readAsString());
      final workerTypeId = decoded is Map ? decoded['workerTypeId'] : null;
      return workerTypeId is String ? workerTypeId : null;
    } on Object {
      return null;
    }
  }

  Future<ToolProfileReleaseAdmission> _verifyInstalled(
    String definitionId,
    int version,
  ) async {
    if (FileSystemEntity.typeSync(
          definitionDirectory(definitionId).path,
          followLinks: false,
        ) !=
        FileSystemEntityType.directory) {
      throw StateError('Tool Profile definition path is unsafe');
    }
    final directory = releaseDirectory(definitionId, version);
    if (FileSystemEntity.typeSync(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw StateError('Tool Profile release is not installed');
    }
    final metadataFile = _releaseMetadataFile(definitionId, version);
    final profile = profileFile(definitionId, version);
    if (FileSystemEntity.typeSync(metadataFile.path, followLinks: false) !=
            FileSystemEntityType.file ||
        FileSystemEntity.typeSync(profile.path, followLinks: false) !=
            FileSystemEntityType.file) {
      throw StateError('Tool Profile release files are missing');
    }
    if (metadataFile.lengthSync() > maxReleaseMetadataBytes ||
        profile.lengthSync() > ToolProfileReleaseVerifier.maxPayloadBytes) {
      throw const FormatException('Installed Tool Profile is oversized');
    }
    final metadata = jsonDecode(metadataFile.readAsStringSync());
    if (metadata is! Map) {
      throw const FormatException('Installed Tool Profile metadata is invalid');
    }
    final release = Map<String, Object?>.from(metadata);
    if (release['profileDefinitionId'] != definitionId ||
        release['releaseVersion'] != version) {
      throw const FormatException(
          'Installed Tool Profile path identity mismatch');
    }
    final diskProfile = jsonDecode(profile.readAsStringSync());
    if (diskProfile is! Map ||
        canonicalJson(diskProfile) != canonicalJson(release['profile'])) {
      throw StateError('Installed Tool Profile content has changed');
    }
    return ToolProfileReleaseVerifier.verify(
      input: release,
      trustPolicy: trustPolicy,
      expectedWorkerTypeId: release['workerTypeId'] as String,
    );
  }

  Future<bool> _shouldDiscardInvalidRelease(
    String definitionId,
    int version,
  ) async {
    try {
      final metadata = jsonDecode(
        await _releaseMetadataFile(definitionId, version).readAsString(),
      );
      if (metadata is! Map ||
          metadata['publisher'] is! String ||
          metadata['signingKeyId'] is! String ||
          metadata['payloadDigest'] is! String) {
        return true;
      }
      final publisher = metadata['publisher'] as String;
      final keyId = metadata['signingKeyId'] as String;
      final digest = metadata['payloadDigest'] as String;
      if (trustPolicy.isToolProfileReleaseRevoked(
        publisher: publisher,
        signingKeyId: keyId,
        digest: digest,
        releaseId: '$definitionId@$version',
      )) {
        return true;
      }
      // Keep releases whose signing root has not been delivered to this
      // Workspace, but never make them active or use them for resolution.
      return trustPolicy.hasTrustedSigningKey(publisher, keyId);
    } on Object {
      return true;
    }
  }

  Future<bool> _belongsToWorker(
    String definitionId,
    int version,
    String workerTypeId,
  ) async {
    try {
      final value = jsonDecode(
        await _releaseMetadataFile(definitionId, version).readAsString(),
      );
      return value is Map && value['workerTypeId'] == workerTypeId;
    } on Object {
      return false;
    }
  }

  Future<void> _enforceRetention(String definitionId) async {
    final versions = await installedVersions(definitionId);
    final state = await _readState(definitionId);
    final keep = <int>{
      ...versions.take(retentionLimit),
      if (state?['activeVersion'] is int) state!['activeVersion'] as int,
      if (state?['lastKnownGoodVersion'] is int)
        state!['lastKnownGoodVersion'] as int,
      if (state?['stableVersion'] is int) state!['stableVersion'] as int,
    };
    // The cap is strict: active and LKG win; newer releases fill remaining slots.
    final orderedKeep = <int>[
      if (state?['activeVersion'] is int) state!['activeVersion'] as int,
      if (state?['lastKnownGoodVersion'] is int)
        state!['lastKnownGoodVersion'] as int,
      if (state?['stableVersion'] is int) state!['stableVersion'] as int,
      ...versions,
    ].where(keep.contains).toSet().take(retentionLimit).toSet();
    for (final version
        in versions.where((version) => !orderedKeep.contains(version))) {
      final directory = releaseDirectory(definitionId, version);
      if (await directory.exists()) await directory.delete(recursive: true);
    }
  }

  Future<List<String>> _definitionIds() async {
    if (!await profilesRoot.exists()) return const [];
    final definitions = <String>[];
    await for (final entity in profilesRoot.list(followLinks: false)) {
      if (entity is! Directory ||
          await FileSystemEntity.type(entity.path, followLinks: false) !=
              FileSystemEntityType.directory) {
        continue;
      }
      final name = entity.path.split(Platform.pathSeparator).last;
      try {
        definitions.add(_safeDefinitionId(name));
      } on FormatException {
        continue;
      }
    }
    if (definitions.length > maxDefinitions) {
      throw StateError('Workspace Profile cache has too many definitions');
    }
    return definitions;
  }

  Future<int> _cachedReleaseCount() async {
    var total = 0;
    for (final definitionId in await _definitionIds()) {
      total += (await installedVersions(definitionId)).length;
      if (total >= maxCachedReleases) return total;
    }
    return total;
  }

  Future<Map<String, Object?>?> _readState(String definitionId) async {
    final definitionType = FileSystemEntity.typeSync(
      definitionDirectory(definitionId).path,
      followLinks: false,
    );
    if (definitionType == FileSystemEntityType.link ||
        (definitionType != FileSystemEntityType.notFound &&
            definitionType != FileSystemEntityType.directory)) {
      throw const FormatException('Tool Profile definition path is unsafe');
    }
    final file = _releaseStateFile(definitionId);
    final fileType = FileSystemEntity.typeSync(file.path, followLinks: false);
    if (fileType == FileSystemEntityType.notFound) return null;
    if (fileType != FileSystemEntityType.file) {
      throw const FormatException('Tool Profile release state path is unsafe');
    }
    if (file.lengthSync() > 16 * 1024) {
      throw const FormatException('Tool Profile release state is oversized');
    }
    final value = jsonDecode(file.readAsStringSync());
    if (value is! Map || value['schemaVersion'] != 1) {
      throw const FormatException('Tool Profile release state is invalid');
    }
    for (final key in [
      'activeVersion',
      'lastKnownGoodVersion',
      'stableVersion',
    ]) {
      final version = value[key];
      if (version != null &&
          (version is! int || version < 1 || version > 0x7fffffff)) {
        throw FormatException('Tool Profile $key is invalid');
      }
    }
    return Map<String, Object?>.from(value);
  }

  Future<void> _writeState(
      String definitionId, Map<String, Object?> value) async {
    await definitionDirectory(definitionId).create(recursive: true);
    await _atomicWrite(_releaseStateFile(definitionId), canonicalJson(value));
  }

  Future<void> _atomicWrite(File target, String contents) async {
    await target.parent.create(recursive: true);
    final existingType = await FileSystemEntity.type(
      target.path,
      followLinks: false,
    );
    if (existingType != FileSystemEntityType.notFound &&
        existingType != FileSystemEntityType.file) {
      throw StateError('Tool Profile state target is unsafe');
    }
    final temporary = File(
      '${target.path}.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}',
    );
    await temporary.writeAsString(contents, flush: true);
    await fileSystemPlatform.restrictPermissions(temporary.path,
        directory: false);
    await temporary.rename(target.path);
    await fileSystemPlatform.restrictPermissions(target.path, directory: false);
    await fileSystemPlatform.restrictPermissions(target.parent.path,
        directory: true);
  }

  Future<T> _withLock<T>(Future<T> Function() action) async {
    await profilesRoot.create(recursive: true);
    await fileSystemPlatform.restrictPermissions(profilesRoot.path,
        directory: true);
    final lockFile =
        File('${profilesRoot.path}${Platform.pathSeparator}.profiles.lock');
    final lockType = await FileSystemEntity.type(
      lockFile.path,
      followLinks: false,
    );
    if (lockType != FileSystemEntityType.notFound &&
        lockType != FileSystemEntityType.file) {
      throw StateError('Tool Profile lock path is unsafe');
    }
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

String _safeDefinitionId(String value) {
  if (!RegExp(r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$').hasMatch(value) ||
      value.length > 96) {
    throw FormatException('Tool Profile definition ID is invalid');
  }
  return value;
}

int _safeVersion(int value) {
  if (value < 1 || value > 0x7fffffff) {
    throw FormatException('Tool Profile release version is invalid');
  }
  return value;
}
