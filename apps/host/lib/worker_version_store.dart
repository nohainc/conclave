import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';
import 'package:crypto/crypto.dart';

import 'platform_runtime.dart';
import 'worker_release_manifest.dart';
import 'worker_release_verifier.dart';
import 'worker_candidate_validator.dart';
import 'worker_trust_policy.dart';

enum WorkerUpdatePolicy { automatic, notify, pinned }

class WorkerActivationDeferred implements Exception {
  const WorkerActivationDeferred();

  @override
  String toString() => 'WorkerActivationDeferred';
}

class WorkerReleaseState {
  const WorkerReleaseState({
    required this.updatePolicy,
    required this.activeVersion,
    required this.lastKnownGoodVersion,
    this.pinnedVersion,
  });

  final WorkerUpdatePolicy updatePolicy;
  final String? pinnedVersion;
  final String? activeVersion;
  final String? lastKnownGoodVersion;
}

/// Owns immutable native Worker versions and their active-version pointers.
/// Provider/session state and logs live outside version directories, so an
/// executable upgrade or rollback never changes Worker-owned state.
class WorkerVersionStore {
  WorkerVersionStore({
    required this.workersRoot,
    required this.trustPolicy,
    required this.allowedPermissions,
    String? platform,
    PlatformRuntime? fileSystemPlatform,
    Set<String> supportedProtocolVersions = const {
      localWorkerProtocolVersion,
    },
    required this.workerStateSchemaVersion,
    this.hasActiveAssignments,
    this.candidateHealthCheck,
    this.retentionLimit = 3,
    this.maxArchiveBytes = WorkerReleaseVerifier.maxArtifactBytes,
  })  : platform = platform ?? currentWorkerPlatform(),
        fileSystemPlatform = fileSystemPlatform ?? currentPlatformRuntime,
        supportedProtocolVersions =
            Set.unmodifiable(supportedProtocolVersions) {
    if (retentionLimit < 2) {
      throw ArgumentError.value(
        retentionLimit,
        'retentionLimit',
        'must retain active and last-known-good versions',
      );
    }
  }

  final Directory workersRoot;
  final WorkerTrustPolicy trustPolicy;
  final Set<WorkerPermission> allowedPermissions;
  final String platform;
  final PlatformRuntime fileSystemPlatform;
  final Set<String> supportedProtocolVersions;
  final int workerStateSchemaVersion;
  final bool Function()? hasActiveAssignments;
  final WorkerCandidateHealthCheck? candidateHealthCheck;
  final int retentionLimit;
  final int maxArchiveBytes;

  Directory _typeRoot(String workerTypeId) =>
      Directory('${workersRoot.path}${Platform.pathSeparator}'
          '${_safeTypeId(workerTypeId)}');

  Directory versionsDirectory(String workerTypeId) => Directory(
      '${_typeRoot(workerTypeId).path}${Platform.pathSeparator}versions');

  Directory stateDirectory(String workerTypeId) => Directory(
      '${_typeRoot(workerTypeId).path}${Platform.pathSeparator}state');

  Directory logsDirectory(String workerTypeId) =>
      Directory('${_typeRoot(workerTypeId).path}${Platform.pathSeparator}logs');

  File releaseStateFile(String workerTypeId) => File(
        '${_typeRoot(workerTypeId).path}${Platform.pathSeparator}release-state.json',
      );

  Directory versionDirectory(String workerTypeId, String version) =>
      Directory('${versionsDirectory(workerTypeId).path}'
          '${Platform.pathSeparator}${_safeVersion(version)}');

  /// Extracts and verifies an immutable release. By default, activation runs
  /// the candidate initialize/passive-probe transaction first.
  Future<Directory> installArchive({
    required Object? manifestInput,
    required List<int> archiveBytes,
    required String expectedWorkerTypeId,
    bool activate = true,
  }) async {
    final manifest = WorkerReleaseManifest.parse(manifestInput);
    if (manifest.workerTypeId != _safeTypeId(expectedWorkerTypeId) ||
        manifest.platform != platform) {
      throw const FormatException('Worker release identity is invalid');
    }
    if (archiveBytes.isEmpty || archiveBytes.length > maxArchiveBytes) {
      throw StateError('Worker archive is empty or exceeds the size limit');
    }
    if (sha256.convert(archiveBytes).toString() != manifest.archiveSha256) {
      throw StateError('Worker archive SHA-256 does not match its manifest');
    }

    final typeRoot = _typeRoot(expectedWorkerTypeId);
    final versionsRoot = versionsDirectory(expectedWorkerTypeId);
    await workersRoot.create(recursive: true);
    await typeRoot.create(recursive: true);
    await versionsRoot.create(recursive: true);
    await stateDirectory(expectedWorkerTypeId).create(recursive: true);
    await logsDirectory(expectedWorkerTypeId).create(recursive: true);
    await cleanupOrphanStagingDirectories(workerTypeId: expectedWorkerTypeId);
    await fileSystemPlatform.restrictPermissions(
      workersRoot.path,
      directory: true,
    );
    for (final directory in [
      typeRoot,
      versionsRoot,
      stateDirectory(expectedWorkerTypeId),
      logsDirectory(expectedWorkerTypeId),
    ]) {
      await fileSystemPlatform.restrictPermissions(
        directory.path,
        directory: true,
      );
    }

    final target =
        versionDirectory(expectedWorkerTypeId, manifest.workerVersion);
    final manifestFile =
        _manifestFile(expectedWorkerTypeId, manifest.workerVersion);
    if (await target.exists()) {
      if (!await manifestFile.exists()) {
        throw StateError('installed Worker version is missing its manifest');
      }
      final priorManifest = jsonDecode(await manifestFile.readAsString());
      if (_canonicalJson(priorManifest) != _canonicalJson(manifest.toJson())) {
        throw StateError(
            'Worker version is already installed with different metadata');
      }
      await WorkerReleaseVerifier.verifyInstalled(
        manifestInput: priorManifest,
        packageRoot: target,
        expectedWorkerTypeId: expectedWorkerTypeId,
        platform: platform,
        trustPolicy: trustPolicy,
        allowedPermissions: allowedPermissions,
        supportedProtocolVersions: supportedProtocolVersions,
        readableStateSchemaVersion: workerStateSchemaVersion,
      );
      if (activate) {
        await activateCandidate(expectedWorkerTypeId, manifest.workerVersion);
      }
      return target;
    }

    final staging = Directory(
      '${versionsRoot.path}${Platform.pathSeparator}'
      '.staging-${manifest.workerVersion}-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await _extractArchive(archiveBytes, staging);
      await WorkerReleaseVerifier.verify(
        manifestInput: manifest.toJson(),
        packageRoot: staging,
        archiveBytes: archiveBytes,
        expectedWorkerTypeId: expectedWorkerTypeId,
        platform: platform,
        trustPolicy: trustPolicy,
        allowedPermissions: allowedPermissions,
        supportedProtocolVersions: supportedProtocolVersions,
        readableStateSchemaVersion: workerStateSchemaVersion,
      );
      final stagedManifest = File(
        '${staging.path}${Platform.pathSeparator}manifest.json',
      );
      if (await stagedManifest.exists()) {
        final embeddedManifest =
            jsonDecode(await stagedManifest.readAsString());
        if (_canonicalJson(embeddedManifest) !=
            _canonicalJson(manifest.toJson())) {
          throw StateError(
              'Worker archive manifest differs from signed release metadata');
        }
      } else {
        await stagedManifest.writeAsString(
          const JsonEncoder.withIndent('  ').convert(manifest.toJson()),
          flush: true,
        );
      }
      await staging.rename(target.path);
    } catch (_) {
      if (await staging.exists()) await staging.delete(recursive: true);
      rethrow;
    }

    if (activate) {
      await activateCandidate(expectedWorkerTypeId, manifest.workerVersion);
    }
    return target;
  }

  /// Activates a previously healthy installed release for rollback/use.
  /// Unvalidated releases must go through [activateCandidate].
  Future<void> activateVersion(String workerTypeId, String version) async {
    if (hasActiveAssignments?.call() ?? false) {
      throw const WorkerActivationDeferred();
    }
    final typeId = _safeTypeId(workerTypeId);
    final safeVersion = _safeVersion(version);
    final packageRoot = versionDirectory(typeId, safeVersion);
    final manifestFile = _manifestFile(typeId, safeVersion);
    if (!await packageRoot.exists() || !await manifestFile.exists()) {
      throw StateError('Worker version is not installed');
    }
    final manifestValue = jsonDecode(await manifestFile.readAsString());
    final admission = await WorkerReleaseVerifier.verifyInstalled(
      manifestInput: manifestValue,
      packageRoot: packageRoot,
      expectedWorkerTypeId: typeId,
      platform: platform,
      trustPolicy: trustPolicy,
      allowedPermissions: allowedPermissions,
      supportedProtocolVersions: supportedProtocolVersions,
      readableStateSchemaVersion: workerStateSchemaVersion,
    );
    if (admission.manifest.workerVersion != safeVersion) {
      throw StateError(
          'Worker release version does not match its install path');
    }

    final stateFile = releaseStateFile(typeId);
    final current = await _readReleaseState(typeId);
    final healthyVersions = _healthyVersions(current);
    if (safeVersion != current?['activeVersion'] &&
        safeVersion != current?['lastKnownGoodVersion'] &&
        !healthyVersions.contains(safeVersion)) {
      throw StateError('Worker version has not passed candidate validation');
    }
    if (_readUpdatePolicy(current) == WorkerUpdatePolicy.pinned &&
        current?['pinnedVersion'] != safeVersion) {
      throw StateError('Worker version is pinned to another release');
    }
    final previousActive = current?['activeVersion'];
    final lastKnownGood =
        previousActive is String && previousActive != safeVersion
            ? previousActive
            : current?['lastKnownGoodVersion'];
    await _writeReleaseState(typeId, {
      'schemaVersion': 1,
      'updatePolicy': _readUpdatePolicy(current).name,
      if (current?['pinnedVersion'] case final String pinnedVersion)
        'pinnedVersion': pinnedVersion,
      'activeVersion': safeVersion,
      if (lastKnownGood is String) 'lastKnownGoodVersion': lastKnownGood,
      if (healthyVersions.isNotEmpty) 'healthyVersions': healthyVersions,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    });
    await _enforceRetention(typeId);
    // Keep this reference alive through the commit; it also forces state path
    // validation before a successful activation is reported.
    if (!await stateFile.exists()) {
      throw StateError('Worker release state was not saved');
    }
  }

  /// Runs a newly installed immutable release through initialize and passive
  /// probe before recording it as healthy and changing the active pointer.
  Future<void> activateCandidate(String workerTypeId, String version) async {
    final typeId = _safeTypeId(workerTypeId);
    final safeVersion = _safeVersion(version);
    if (hasActiveAssignments?.call() ?? false) {
      throw const WorkerActivationDeferred();
    }
    final candidateHealthCheck = this.candidateHealthCheck;
    if (candidateHealthCheck == null) {
      throw StateError('Worker candidate validation is not configured');
    }
    final packageRoot = versionDirectory(typeId, safeVersion);
    final manifestFile = _manifestFile(typeId, safeVersion);
    if (!await packageRoot.exists() || !await manifestFile.exists()) {
      throw StateError('Worker candidate is not installed');
    }
    final admission = await WorkerReleaseVerifier.verifyInstalled(
      manifestInput: jsonDecode(await manifestFile.readAsString()),
      packageRoot: packageRoot,
      expectedWorkerTypeId: typeId,
      platform: platform,
      trustPolicy: trustPolicy,
      allowedPermissions: allowedPermissions,
      supportedProtocolVersions: supportedProtocolVersions,
      readableStateSchemaVersion: workerStateSchemaVersion,
    );
    if (admission.manifest.workerVersion != safeVersion) {
      throw StateError(
          'Worker candidate version does not match its install path');
    }
    final current = await _readReleaseState(typeId);
    if (_readUpdatePolicy(current) == WorkerUpdatePolicy.pinned &&
        current?['pinnedVersion'] != safeVersion) {
      throw StateError('Worker version is pinned to another release');
    }
    try {
      await candidateHealthCheck.validate(
        admission,
        stateDirectory: stateDirectory(typeId),
      );
    } on WorkerCandidateValidationFailure catch (failure) {
      await recordCandidateFailure(
        typeId,
        safeVersion,
        issueCode: failure.issueCode,
        diagnostic: failure.safeDiagnostic,
      );
      rethrow;
    } on Object {
      await recordCandidateFailure(
        typeId,
        safeVersion,
        issueCode: WorkerIssueCode.workerInternalFailure,
        diagnostic: 'Candidate initialize or passive probe failed',
      );
      rethrow;
    }
    if (hasActiveAssignments?.call() ?? false) {
      throw const WorkerActivationDeferred();
    }

    final previousActive = current?['activeVersion'];
    final lastKnownGood =
        previousActive is String && previousActive != safeVersion
            ? previousActive
            : current?['lastKnownGoodVersion'];
    final healthyVersions = <String>{
      ..._healthyVersions(current),
      if (previousActive is String) previousActive,
      safeVersion,
    }.toList()
      ..sort(_compareVersionsDescending);
    await _writeReleaseState(typeId, {
      'schemaVersion': 1,
      'updatePolicy': _readUpdatePolicy(current).name,
      if (current?['pinnedVersion'] case final String pinnedVersion)
        'pinnedVersion': pinnedVersion,
      'activeVersion': safeVersion,
      if (lastKnownGood is String) 'lastKnownGoodVersion': lastKnownGood,
      'healthyVersions': healthyVersions,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    });
    await _clearCandidateFailure(typeId);
    await _enforceRetention(typeId);
  }

  Future<void> recordCandidateFailure(
    String workerTypeId,
    String version, {
    required String issueCode,
    required String diagnostic,
  }) async {
    final typeId = _safeTypeId(workerTypeId);
    final safeVersion = _safeVersion(version);
    final safeIssue = RegExp(r'^[a-z][a-z0-9_]{0,63}$').hasMatch(issueCode)
        ? issueCode
        : WorkerIssueCode.workerInternalFailure;
    final safeDiagnostic = diagnostic
        .replaceAll(RegExp(r'[^\x20-\x7E\n\t]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final bounded = safeDiagnostic.length <= 256
        ? safeDiagnostic
        : safeDiagnostic.substring(0, 256);
    final file = _candidateFailureFile(typeId);
    await file.parent.create(recursive: true);
    final temporary = File(
      '${file.path}.tmp-${DateTime.now().microsecondsSinceEpoch}',
    );
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'schemaVersion': 1,
        'version': safeVersion,
        'issueCode': safeIssue,
        'diagnostic': bounded.isEmpty ? 'Candidate validation failed' : bounded,
        'failedAt': DateTime.now().toUtc().toIso8601String(),
      }),
      flush: true,
    );
    try {
      await temporary.rename(file.path);
    } on Object {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  Future<Map<String, Object?>?> lastCandidateFailure(
    String workerTypeId,
  ) async {
    final file = _candidateFailureFile(_safeTypeId(workerTypeId));
    if (!await file.exists()) return null;
    final value = jsonDecode(await file.readAsString());
    if (value is! Map ||
        value['schemaVersion'] != 1 ||
        value['version'] is! String ||
        value['issueCode'] is! String ||
        value['diagnostic'] is! String) {
      throw const FormatException('Worker candidate diagnostic is invalid');
    }
    return Map<String, Object?>.from(value);
  }

  File _candidateFailureFile(String workerTypeId) => File(
        '${_typeRoot(workerTypeId).path}${Platform.pathSeparator}'
        'candidate-failure.json',
      );

  Future<void> _clearCandidateFailure(String workerTypeId) async {
    final file = _candidateFailureFile(workerTypeId);
    if (await file.exists()) await file.delete();
  }

  Future<void> rollbackToLastKnownGood(String workerTypeId) async {
    final state = await _readReleaseState(_safeTypeId(workerTypeId));
    final version = state?['lastKnownGoodVersion'];
    if (version is! String) {
      throw StateError('Worker has no last-known-good version');
    }
    if (_readUpdatePolicy(state) == WorkerUpdatePolicy.pinned &&
        state?['pinnedVersion'] != version) {
      await setUpdatePolicy(workerTypeId, WorkerUpdatePolicy.notify);
    }
    await activateVersion(workerTypeId, version);
  }

  Future<WorkerReleaseState> releaseState(String workerTypeId) async {
    final state = await _readReleaseState(_safeTypeId(workerTypeId));
    return WorkerReleaseState(
      updatePolicy: _readUpdatePolicy(state),
      pinnedVersion: state?['pinnedVersion'] as String?,
      activeVersion: state?['activeVersion'] as String?,
      lastKnownGoodVersion: state?['lastKnownGoodVersion'] as String?,
    );
  }

  Future<void> setUpdatePolicy(
    String workerTypeId,
    WorkerUpdatePolicy policy, {
    String? pinnedVersion,
  }) async {
    final typeId = _safeTypeId(workerTypeId);
    final current = await _readReleaseState(typeId);
    if (current == null) {
      throw StateError('Worker has no installed version');
    }
    if (policy == WorkerUpdatePolicy.pinned) {
      final version =
          _safeVersion(pinnedVersion ?? current['activeVersion']! as String);
      if (!await versionDirectory(typeId, version).exists()) {
        throw StateError('Pinned Worker version is not installed');
      }
      await WorkerReleaseVerifier.verifyInstalled(
        manifestInput:
            jsonDecode(await _manifestFile(typeId, version).readAsString()),
        packageRoot: versionDirectory(typeId, version),
        expectedWorkerTypeId: typeId,
        platform: platform,
        trustPolicy: trustPolicy,
        allowedPermissions: allowedPermissions,
        supportedProtocolVersions: supportedProtocolVersions,
        readableStateSchemaVersion: workerStateSchemaVersion,
      );
      if (current['activeVersion'] != version) {
        if (current['updatePolicy'] == WorkerUpdatePolicy.pinned.name) {
          await _writeReleaseState(
              typeId,
              {
                ...current,
                'updatePolicy': WorkerUpdatePolicy.notify.name,
              }..remove('pinnedVersion'));
        }
        await activateVersion(typeId, version);
      }
      final refreshed = await _readReleaseState(typeId);
      await _writeReleaseState(typeId, {
        ...refreshed!,
        'updatePolicy': WorkerUpdatePolicy.pinned.name,
        'pinnedVersion': version,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      });
      return;
    }
    await _writeReleaseState(
        typeId,
        {
          ...current,
          'updatePolicy': policy.name,
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
        }..remove('pinnedVersion'));
  }

  Future<List<String>> installedVersions(String workerTypeId) async {
    final typeId = _safeTypeId(workerTypeId);
    final root = versionsDirectory(typeId);
    if (!await root.exists()) return const [];
    final versions = <String>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = entity.path.split(Platform.pathSeparator).last;
      if (name.startsWith('.staging-')) continue;
      try {
        final version = _safeVersion(name);
        final manifest = _manifestFile(typeId, version);
        if (await manifest.exists()) versions.add(version);
      } on FormatException {
        continue;
      }
    }
    versions.sort(_compareVersionsDescending);
    return List.unmodifiable(versions);
  }

  Future<String?> activeVersion(String workerTypeId) async =>
      (await _readReleaseState(_safeTypeId(workerTypeId)))?['activeVersion']
          as String?;

  /// Returns verified metadata for the active immutable release, if installed.
  Future<WorkerReleaseManifest?> activeManifest(String workerTypeId) async {
    final version = await activeVersion(workerTypeId);
    if (version == null) return null;
    await activeExecutable(workerTypeId);
    return WorkerReleaseManifest.parse(
      jsonDecode(
        await _manifestFile(_safeTypeId(workerTypeId), version).readAsString(),
      ),
    );
  }

  /// Checks release metadata against this Workspace before offering it as an
  /// update. Artifact bytes and executable contents are verified on download.
  Future<bool> isCompatibleRelease({
    required Object? manifestInput,
    required String workerTypeId,
    required String version,
    required String releasePlatform,
    required String releaseChannel,
  }) async {
    try {
      final manifest = WorkerReleaseManifest.parse(manifestInput);
      if (manifest.workerTypeId != workerTypeId ||
          manifest.workerVersion != version ||
          manifest.platform != platform ||
          releasePlatform != platform ||
          manifest.releaseChannel != releaseChannel) {
        return false;
      }
      if (!supportedProtocolVersions.any(manifest.supportsProtocol) ||
          workerStateSchemaVersion < manifest.stateReadMin ||
          workerStateSchemaVersion > manifest.stateReadMax) {
        return false;
      }
      final permissions =
          manifest.permissions.map(parseWorkerPermission).toSet();
      trustPolicy.requirePermissions(permissions, allowedPermissions);
      return await trustPolicy.verifyWorkerReleaseManifest(manifest.toJson());
    } on Object {
      return false;
    }
  }

  Future<String?> lastKnownGoodVersion(String workerTypeId) async =>
      (await _readReleaseState(
          _safeTypeId(workerTypeId)))?['lastKnownGoodVersion'] as String?;

  Future<File?> activeExecutable(String workerTypeId) async {
    final typeId = _safeTypeId(workerTypeId);
    final version = await activeVersion(typeId);
    if (version == null) return null;
    final manifestFile = _manifestFile(typeId, version);
    if (!await manifestFile.exists()) {
      throw StateError('active Worker metadata is missing');
    }
    final manifest = WorkerReleaseManifest.parse(
      jsonDecode(await manifestFile.readAsString()),
    );
    final admission = await WorkerReleaseVerifier.verifyInstalled(
      manifestInput: manifest.toJson(),
      packageRoot: versionDirectory(typeId, version),
      expectedWorkerTypeId: typeId,
      platform: platform,
      trustPolicy: trustPolicy,
      allowedPermissions: allowedPermissions,
      supportedProtocolVersions: supportedProtocolVersions,
      readableStateSchemaVersion: workerStateSchemaVersion,
    );
    if (admission.manifest.workerVersion != version) {
      throw StateError(
          'active Worker version does not match its release metadata');
    }
    return admission.executable;
  }

  /// Removes abandoned extraction directories left by interrupted installs.
  Future<void> cleanupOrphanStagingDirectories({
    String? workerTypeId,
    Duration minimumAge = const Duration(hours: 1),
  }) async {
    final typeRoots = <Directory>[];
    if (workerTypeId != null) {
      typeRoots.add(_typeRoot(workerTypeId));
    } else if (await workersRoot.exists()) {
      await for (final entity in workersRoot.list(followLinks: false)) {
        if (entity is Directory) {
          final typeId = entity.path.split(Platform.pathSeparator).last;
          if (RegExp(r'^[a-z0-9][a-z0-9._-]*$').hasMatch(typeId)) {
            typeRoots.add(entity);
          }
        }
      }
    }
    for (final typeRoot in typeRoots) {
      final versions =
          Directory('${typeRoot.path}${Platform.pathSeparator}versions');
      if (!await versions.exists()) continue;
      await for (final entity in versions.list(followLinks: false)) {
        if (entity is Directory &&
            entity.path
                .split(Platform.pathSeparator)
                .last
                .startsWith('.staging-')) {
          final modified = (await entity.stat()).modified;
          if (DateTime.now().difference(modified) >= minimumAge) {
            await entity.delete(recursive: true);
          }
        }
      }
    }
  }

  File _manifestFile(String workerTypeId, String version) => File(
        '${versionDirectory(workerTypeId, version).path}'
        '${Platform.pathSeparator}manifest.json',
      );

  Future<void> _extractArchive(List<int> bytes, Directory staging) async {
    await staging.create(recursive: true);
    final tarBuilder = BytesBuilder(copy: false);
    var expandedTarLength = 0;
    await for (final chunk
        in gzip.decoder.bind(Stream<List<int>>.value(bytes))) {
      expandedTarLength += chunk.length;
      if (expandedTarLength > maxArchiveBytes) {
        throw StateError('expanded Worker archive exceeds the size limit');
      }
      tarBuilder.add(chunk);
    }
    final entries =
        TarDecoder().decodeBytes(tarBuilder.takeBytes(), verify: true);
    if (entries.isEmpty || entries.length > 10000) {
      throw StateError('Worker archive has an invalid entry count');
    }
    final seen = <String>{};
    var expandedFileBytes = 0;
    for (final entry in entries) {
      final relative = _safeArchivePath(entry.name);
      if (!seen.add(relative)) {
        throw StateError('Worker archive contains duplicate paths');
      }
      if (entry.isSymbolicLink) {
        throw StateError('Worker archives cannot contain links');
      }
      final destination = '${staging.path}${Platform.pathSeparator}'
          '${relative.replaceAll('/', Platform.pathSeparator)}';
      if (entry.isDirectory) {
        await Directory(destination).create(recursive: true);
        continue;
      }
      if (!entry.isFile) {
        throw StateError('Worker archive contains a special file');
      }
      expandedFileBytes += entry.size;
      if (expandedFileBytes > maxArchiveBytes) {
        throw StateError('expanded Worker archive exceeds the size limit');
      }
      final contents = entry.readBytes();
      if (contents == null || contents.length != entry.size) {
        throw StateError('Worker archive contains a truncated file');
      }
      final output = File(destination);
      await output.parent.create(recursive: true);
      await output.writeAsBytes(contents, flush: true);
      if (!Platform.isWindows) {
        final mode = entry.unixPermissions & 0x1ff;
        final chmod =
            await Process.run('chmod', [mode.toRadixString(8), output.path]);
        if (chmod.exitCode != 0) {
          throw StateError('could not preserve Worker executable mode');
        }
      }
    }
  }

  Future<Map<String, Object?>?> _readReleaseState(String workerTypeId) async {
    final file = releaseStateFile(workerTypeId);
    if (!await file.exists()) return null;
    final value = jsonDecode(await file.readAsString());
    if (value is! Map || value['schemaVersion'] != 1) {
      throw const FormatException('Worker release state is invalid');
    }
    final active = value['activeVersion'];
    final lastKnownGood = value['lastKnownGoodVersion'];
    final policyName = value['updatePolicy'] ?? WorkerUpdatePolicy.notify.name;
    final pinnedVersion = value['pinnedVersion'];
    final healthy = value['healthyVersions'];
    if (active is! String ||
        (lastKnownGood != null && lastKnownGood is! String) ||
        policyName is! String ||
        !WorkerUpdatePolicy.values.any((policy) => policy.name == policyName) ||
        (pinnedVersion != null && pinnedVersion is! String) ||
        (healthy != null &&
            (healthy is! List || healthy.any((item) => item is! String)))) {
      throw const FormatException('Worker release state pointers are invalid');
    }
    _safeVersion(active);
    if (lastKnownGood is String) _safeVersion(lastKnownGood);
    if (pinnedVersion is String) _safeVersion(pinnedVersion);
    if (healthy is List) {
      for (final version in healthy.cast<String>()) {
        _safeVersion(version);
      }
    }
    if ((policyName == WorkerUpdatePolicy.pinned.name) !=
        (pinnedVersion is String)) {
      throw const FormatException('Worker pin state is invalid');
    }
    return Map<String, Object?>.from(value);
  }

  List<String> _healthyVersions(Map<String, Object?>? state) {
    final versions = state?['healthyVersions'];
    if (versions is! List) return const [];
    return versions.cast<String>();
  }

  Future<void> _writeReleaseState(
    String workerTypeId,
    Map<String, Object?> value,
  ) async {
    final file = releaseStateFile(workerTypeId);
    final temporary = File(
      '${file.path}.tmp-${DateTime.now().microsecondsSinceEpoch}',
    );
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert(value),
      flush: true,
    );
    try {
      await temporary.rename(file.path);
    } on Object {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  Future<void> _enforceRetention(String workerTypeId) async {
    final state = await _readReleaseState(workerTypeId);
    final versionsRoot = versionsDirectory(workerTypeId);
    if (!await versionsRoot.exists()) return;
    final installed = <({String version, DateTime installedAt})>[];
    await for (final entity in versionsRoot.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = entity.path.split(Platform.pathSeparator).last;
      if (name.startsWith('.staging-')) continue;
      try {
        installed.add((
          version: _safeVersion(name),
          installedAt: (await entity.stat()).modified
        ));
      } on FormatException {
        continue;
      }
    }
    installed.sort((a, b) => b.installedAt.compareTo(a.installedAt));
    final keep = <String>{
      if (state?['activeVersion'] is String) state!['activeVersion'] as String,
      if (state?['lastKnownGoodVersion'] is String)
        state!['lastKnownGoodVersion'] as String,
    };
    for (final entry in installed) {
      if (keep.length >= retentionLimit) break;
      keep.add(entry.version);
    }
    for (final entry in installed) {
      if (keep.contains(entry.version)) continue;
      await versionDirectory(workerTypeId, entry.version)
          .delete(recursive: true);
      final manifest = _manifestFile(workerTypeId, entry.version);
      if (await manifest.exists()) await manifest.delete();
    }
  }

  String _safeArchivePath(String path) {
    if (path.isEmpty ||
        path.startsWith('/') ||
        path.startsWith('\\') ||
        path.contains('\\') ||
        RegExp(r'^[A-Za-z]:').hasMatch(path)) {
      throw StateError('Worker archive contains an invalid path');
    }
    final normalized =
        path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    final parts = normalized.split('/');
    if (parts.isEmpty ||
        parts.any((part) =>
            part.isEmpty ||
            part == '.' ||
            part == '..' ||
            part.contains(':'))) {
      throw StateError('Worker archive contains an invalid path');
    }
    return parts.join('/');
  }

  String _safeTypeId(String value) {
    if (!RegExp(r'^[a-z0-9][a-z0-9._-]*$').hasMatch(value)) {
      throw const FormatException('Worker Type ID is invalid');
    }
    return value;
  }

  String _safeVersion(String value) {
    if (!RegExp(r'^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$')
        .hasMatch(value)) {
      throw const FormatException('Worker version is invalid');
    }
    return value;
  }
}

WorkerUpdatePolicy _readUpdatePolicy(Map<String, Object?>? state) {
  final name = state?['updatePolicy'];
  return WorkerUpdatePolicy.values.firstWhere(
    (policy) => policy.name == name,
    orElse: () => WorkerUpdatePolicy.notify,
  );
}

int _compareVersionsDescending(String left, String right) {
  final a =
      left.split(RegExp(r'[+-]')).first.split('.').map(int.parse).toList();
  final b =
      right.split(RegExp(r'[+-]')).first.split('.').map(int.parse).toList();
  for (var index = 0; index < 3; index++) {
    final comparison = b[index].compareTo(a[index]);
    if (comparison != 0) return comparison;
  }
  return right.compareTo(left);
}

String _canonicalJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return '{${keys.map((key) => '${jsonEncode(key)}:${_canonicalJson(value[key])}').join(',')}}';
  }
  if (value is List) return '[${value.map(_canonicalJson).join(',')}]';
  return jsonEncode(value);
}
