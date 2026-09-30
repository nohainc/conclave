import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';

import 'worker_release_manifest.dart';
import 'worker_trust_policy.dart';

class WorkerReleaseAdmission {
  const WorkerReleaseAdmission({
    required this.manifest,
    required this.packageRoot,
    required this.executable,
    required this.grantedPermissions,
  });

  final WorkerReleaseManifest manifest;
  final Directory packageRoot;
  final File executable;
  final Set<WorkerPermission> grantedPermissions;

  /// Rejects a live executable that does not identify itself exactly as the
  /// signed release metadata selected during admission.
  void validateInitializeResult(
    InitializeResult result, {
    String negotiatedProtocolVersion = localWorkerProtocolVersion,
  }) {
    if (!manifest.supportsProtocol(negotiatedProtocolVersion)) {
      throw StateError(
        'Worker release does not support the negotiated protocol version',
      );
    }
    validateInitializeAdmission(
      result,
      expectedWorkerTypeId: manifest.workerTypeId,
      expectedWorkerVersion: manifest.workerVersion,
      minReadableStateSchema: manifest.stateWrite,
      maxReadableStateSchema: manifest.stateWrite,
      requiredCapabilities: manifest.capabilities.toSet(),
      negotiatedProtocolVersion: negotiatedProtocolVersion,
    );
  }
}

/// Verifies the signed metadata and content hashes of a native Worker artifact.
/// The archive and manifest are detached, avoiding a signature/hash cycle.
abstract final class WorkerReleaseVerifier {
  static const maxArtifactBytes = 512 * 1024 * 1024;

  static Future<WorkerReleaseAdmission> verify({
    required Object? manifestInput,
    required Directory packageRoot,
    required List<int> archiveBytes,
    required String expectedWorkerTypeId,
    required String platform,
    required WorkerTrustPolicy trustPolicy,
    required Set<WorkerPermission> allowedPermissions,
    Set<String> supportedProtocolVersions = const {
      localWorkerProtocolVersion,
    },
    required int readableStateSchemaVersion,
  }) =>
      _verify(
        manifestInput: manifestInput,
        packageRoot: packageRoot,
        archiveBytes: archiveBytes,
        expectedWorkerTypeId: expectedWorkerTypeId,
        platform: platform,
        trustPolicy: trustPolicy,
        allowedPermissions: allowedPermissions,
        supportedProtocolVersions: supportedProtocolVersions,
        readableStateSchemaVersion: readableStateSchemaVersion,
      );

  /// Re-verifies an installed immutable version when switching or rolling it
  /// back. Archive integrity was checked before installation; installed
  /// content is checked against its signed package digest here.
  static Future<WorkerReleaseAdmission> verifyInstalled({
    required Object? manifestInput,
    required Directory packageRoot,
    required String expectedWorkerTypeId,
    required String platform,
    required WorkerTrustPolicy trustPolicy,
    required Set<WorkerPermission> allowedPermissions,
    Set<String> supportedProtocolVersions = const {
      localWorkerProtocolVersion,
    },
    required int readableStateSchemaVersion,
  }) =>
      _verify(
        manifestInput: manifestInput,
        packageRoot: packageRoot,
        expectedWorkerTypeId: expectedWorkerTypeId,
        platform: platform,
        trustPolicy: trustPolicy,
        allowedPermissions: allowedPermissions,
        supportedProtocolVersions: supportedProtocolVersions,
        readableStateSchemaVersion: readableStateSchemaVersion,
      );

  static Future<WorkerReleaseAdmission> _verify({
    required Object? manifestInput,
    required Directory packageRoot,
    required String expectedWorkerTypeId,
    required String platform,
    required WorkerTrustPolicy trustPolicy,
    required Set<WorkerPermission> allowedPermissions,
    required Set<String> supportedProtocolVersions,
    required int readableStateSchemaVersion,
    List<int>? archiveBytes,
  }) async {
    final manifest = WorkerReleaseManifest.parse(manifestInput);
    if (manifest.workerTypeId != expectedWorkerTypeId ||
        manifest.platform != platform ||
        (archiveBytes != null &&
            (archiveBytes.isEmpty || archiveBytes.length > maxArtifactBytes))) {
      throw const FormatException(
          'Worker artifact identity or size is invalid');
    }
    if (!supportedProtocolVersions.any(manifest.supportsProtocol)) {
      throw StateError(
          'Worker release does not support a local protocol version');
    }
    if (readableStateSchemaVersion < 1 ||
        readableStateSchemaVersion >
            WorkerProtocolLimits.maxStateSchemaVersion ||
        manifest.stateWrite > WorkerProtocolLimits.maxStateSchemaVersion) {
      throw const FormatException('Worker state schema version is invalid');
    }
    if (readableStateSchemaVersion < manifest.stateReadMin ||
        readableStateSchemaVersion > manifest.stateReadMax) {
      throw StateError(
        'Worker release cannot read the local Worker state schema',
      );
    }

    final declaredPermissions =
        manifest.permissions.map(parseWorkerPermission).toSet();
    trustPolicy.requirePermissions(declaredPermissions, allowedPermissions);

    if (archiveBytes != null) {
      final archiveDigest = sha256.convert(archiveBytes).toString();
      if (archiveDigest != manifest.archiveSha256) {
        throw StateError('Worker archive SHA-256 does not match its manifest');
      }
    }
    final packageDigest = await digestWorkerPackageDirectory(packageRoot);
    if (packageDigest != manifest.packageDigest) {
      throw StateError('Worker package digest does not match its manifest');
    }
    if (!await trustPolicy.verifyWorkerReleaseManifest(manifest.toJson())) {
      throw StateError('Worker release signature is not trusted');
    }

    final root = await packageRoot.resolveSymbolicLinks();
    final executableCandidate = File(
      '$root${Platform.pathSeparator}${manifest.executable.replaceAll('/', Platform.pathSeparator)}',
    );
    final resolvedExecutable = await executableCandidate.resolveSymbolicLinks();
    if (!resolvedExecutable.startsWith('$root${Platform.pathSeparator}') ||
        !await FileSystemEntity.isFile(resolvedExecutable)) {
      throw const FormatException(
          'Worker executable escapes its verified package');
    }
    if (!Platform.isWindows &&
        (await File(resolvedExecutable).stat()).mode & 0x49 == 0) {
      throw const FormatException('Worker executable is not executable');
    }
    return WorkerReleaseAdmission(
      manifest: manifest,
      packageRoot: Directory(root),
      executable: File(resolvedExecutable),
      grantedPermissions: Set.unmodifiable(declaredPermissions),
    );
  }
}

/// Hashes sorted package file paths, executable modes, and file contents.
/// The signed root manifest is excluded to avoid a digest/signature cycle.
Future<String> digestWorkerPackageDirectory(Directory directory) async {
  const maximumFiles = 10000;
  var totalBytes = 0;
  final root = await directory.resolveSymbolicLinks();
  final files = <(String, File, int)>[];
  await for (final entity
      in Directory(root).list(recursive: true, followLinks: false)) {
    if (entity is Link) {
      throw StateError('Worker packages cannot contain symlinks');
    }
    if (entity is! File) continue;
    final relative = entity.path
        .substring(root.length + 1)
        .replaceAll(Platform.pathSeparator, '/');
    if (relative
        .split('/')
        .any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw StateError('Worker package contains an invalid path');
    }
    if (relative == 'manifest.json') continue;
    totalBytes += await entity.length();
    if (totalBytes > WorkerReleaseVerifier.maxArtifactBytes) {
      throw StateError('Worker package exceeds the size limit');
    }
    final mode =
        Platform.isWindows ? 0x1ff : (await entity.stat()).mode & 0x1ff;
    files.add((relative, entity, mode));
    if (files.length > maximumFiles) {
      throw StateError('Worker package has too many files');
    }
  }
  files.sort((left, right) => left.$1.compareTo(right.$1));
  final bytes = BytesBuilder(copy: false);
  for (final (relative, file, mode) in files) {
    bytes
      ..add(utf8.encode(relative))
      ..add([0])
      ..add(utf8.encode(mode.toRadixString(8)))
      ..add([0])
      ..add(await file.readAsBytes())
      ..add([0]);
  }
  return sha256.convert(bytes.takeBytes()).toString();
}
