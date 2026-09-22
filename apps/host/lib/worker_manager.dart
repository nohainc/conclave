import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'worker_executor.dart';
import 'worker_trust_policy.dart';

class WorkerManifest {
  const WorkerManifest({
    required this.workerId,
    required this.version,
    required this.protocolVersion,
    required this.engineVersion,
    required this.executable,
    this.arguments = const [],
    this.publisher,
    this.permissions = const [],
    this.secretEnvironmentVariables = const [],
    this.supportedPlatforms = const [],
    this.releaseChannel = 'stable',
  });

  final String workerId;
  final String version;
  final String protocolVersion;
  final String engineVersion;
  final String executable;
  final List<String> arguments;
  final String? publisher;
  final List<WorkerPermission> permissions;
  final List<String> secretEnvironmentVariables;
  final List<String> supportedPlatforms;
  final String releaseChannel;

  Map<String, Object?> toJson() => {
        'workerId': workerId,
        'version': version,
        'protocolVersion': protocolVersion,
        'engineVersion': engineVersion,
        'executable': executable,
        'arguments': arguments,
        if (publisher != null) 'publisher': publisher,
        'permissions':
            permissions.map((permission) => permission.wireName).toList(),
        'secretEnvironmentVariables': secretEnvironmentVariables,
        'supportedPlatforms': supportedPlatforms,
        'releaseChannel': releaseChannel,
      };
}

class WorkerPackage {
  const WorkerPackage({
    required this.id,
    required this.version,
    required this.bytes,
    required this.digest,
    this.publisher,
    this.signature,
    this.permissions = const [],
    this.manifest,
  });
  final String id;
  final String version;
  final List<int> bytes;
  final String digest;
  final String? publisher;
  final String? signature;
  final List<WorkerPermission> permissions;
  final WorkerManifest? manifest;
}

class InstalledWorker {
  const InstalledWorker({
    required this.workerId,
    required this.version,
    required this.digest,
    required this.active,
    required this.manifest,
  });

  final String workerId;
  final String version;
  final String digest;
  final bool active;
  final Map<String, Object?> manifest;
}

class WorkerManager {
  WorkerManager(this.root,
      {this.trustPolicy,
      this.requireSignature = false,
      this.allowedPermissions = const {},
      this.secretEnvironment = const {},
      String? platformKey,
      this.engineVersion = '0.1.0',
      this.protocolVersion = '4.0'})
      : platformKey = platformKey ?? _currentPlatformKey();
  final Directory root;
  final WorkerTrustPolicy? trustPolicy;

  /// Require a configured trust policy before admitting any package. Keep the
  /// opt-out only for local development and fixture-based tests.
  final bool requireSignature;
  final Set<WorkerPermission> allowedPermissions;

  /// Values are supplied by the Host's secure configuration boundary and are
  /// injected only when a verified manifest names the variable explicitly.
  final Map<String, String> secretEnvironment;
  final String platformKey;
  final String engineVersion;
  final String protocolVersion;

  /// Installs the versions requested by Cloud during Host reconciliation.
  /// The package bytes are fetched by the caller so transport/authentication
  /// stays outside the worker manager, while digest and signature admission
  /// remains centralized here.
  Future<void> reconcile(
    Iterable<Map<String, Object?>> desired, {
    required Future<List<int>> Function(
      String workerId,
      String version,
      String packageR2Key,
    ) download,
  }) async {
    final desiredWorkerIds = <String>{};
    final desiredWorkerVersions = <String, String>{};
    for (final item in desired) {
      final workerId = item['workerId'];
      final version = item['version'];
      final publisher = item['publisher'];
      final packageR2Key = item['packageR2Key'];
      final digest = item['packageDigest'];
      final signature = item['signature'];
      final permissions = item['permissions'];
      final protocolVersion = item['protocolVersion'];
      final minHostVersion = item['minHostVersion'];
      final supportedPlatforms = item['supportedPlatforms'];
      final secretEnvironmentVariables = item['secretEnvironmentVariables'];
      if (workerId is! String ||
          version is! String ||
          publisher is! String ||
          packageR2Key is! String ||
          digest is! String ||
          signature is! String ||
          permissions is! List) {
        throw StateError('Cloud returned an invalid desired worker');
      }
      _validatePathComponent(workerId, 'worker id');
      _validatePathComponent(version, 'worker version');
      desiredWorkerIds.add(workerId);
      desiredWorkerVersions[workerId] = version;
      if (await activeVersion(workerId) == version) {
        // Do not trust the active pointer alone. Re-check the immutable
        // payload, manifest, platform, permissions, and current trust policy
        // on every desired-state sync.
        await _verifiedManifest(workerId, version);
        continue;
      }
      final bytes = await download(workerId, version, packageR2Key);
      await install(WorkerPackage(
        id: workerId,
        version: version,
        bytes: bytes,
        digest: digest,
        publisher: publisher,
        signature: signature,
        permissions:
            permissions.whereType<String>().map(parseWorkerPermission).toList(),
        manifest: WorkerManifest(
          workerId: workerId,
          version: version,
          protocolVersion: protocolVersion is String
              ? protocolVersion
              : this.protocolVersion,
          engineVersion:
              minHostVersion is String ? '>=$minHostVersion' : '>=0.1.0',
          executable: 'package.bin',
          publisher: publisher,
          permissions: permissions
              .whereType<String>()
              .map(parseWorkerPermission)
              .toList(),
          secretEnvironmentVariables: secretEnvironmentVariables is List
              ? secretEnvironmentVariables.whereType<String>().toList()
              : const [],
          supportedPlatforms: supportedPlatforms is List
              ? supportedPlatforms.whereType<String>().toList()
              : const [],
        ),
      ));
    }
    // Desired state is authoritative. A worker no longer referenced by any
    // enabled Worker must stop being executable, including revoked versions.
    final installed = await inventory();
    for (final worker in installed) {
      if (worker.active && !desiredWorkerIds.contains(worker.workerId)) {
        await deactivate(worker.workerId);
      }
    }
    await garbageCollect(keepVersions: desiredWorkerVersions);
  }

  static String _currentPlatformKey() {
    final os = switch (Platform.operatingSystem) {
      'macos' => 'macos',
      'linux' => 'linux',
      'windows' => 'windows',
      final other => other,
    };
    final arch =
        Platform.version.toLowerCase().contains('arm64') ? 'arm64' : 'x64';
    return '$os-$arch';
  }

  Future<Directory> install(WorkerPackage package) async {
    _validatePathComponent(package.id, 'worker id');
    _validatePathComponent(package.version, 'worker version');
    final actual = sha256.convert(package.bytes).toString();
    final canonicalDigest = 'sha256:$actual';
    if (package.digest != actual && package.digest != canonicalDigest) {
      throw StateError('worker digest mismatch');
    }
    if (requireSignature && trustPolicy == null) {
      throw StateError('worker signature verification is not configured');
    }
    if (trustPolicy != null) {
      final publisher = package.publisher;
      final signature = package.signature;
      if (publisher == null ||
          signature == null ||
          !trustPolicy!.verify(
              publisher: publisher,
              digest:
                  package.digest == canonicalDigest ? canonicalDigest : actual,
              signature: signature)) {
        throw StateError('worker signature is not trusted');
      }
      trustPolicy!.requirePermissions(package.permissions, allowedPermissions);
    }
    final manifest = package.manifest ??
        WorkerManifest(
          workerId: package.id,
          version: package.version,
          protocolVersion: '4.0',
          engineVersion: '>=0.1.0',
          executable: 'package.bin',
          publisher: package.publisher,
          permissions: package.permissions,
          secretEnvironmentVariables: const [],
        );
    if (manifest.workerId != package.id ||
        manifest.version != package.version) {
      throw StateError('worker manifest identity does not match package');
    }
    if (manifest.publisher != null &&
        package.publisher != null &&
        manifest.publisher != package.publisher) {
      throw StateError('worker manifest publisher does not match package');
    }
    _requirePermissions(manifest.permissions);
    _validateSecretEnvironment(manifest);
    if (manifest.protocolVersion != protocolVersion ||
        !_satisfiesMinimumVersion(engineVersion, manifest.engineVersion)) {
      throw StateError('worker is incompatible with this Host');
    }
    if (manifest.supportedPlatforms.isNotEmpty &&
        !manifest.supportedPlatforms.contains(platformKey)) {
      throw StateError('worker is not compatible with platform $platformKey');
    }
    final versionRoot = Directory('${root.path}/${package.id}');
    final target = Directory('${versionRoot.path}/${package.version}');
    if (await target.exists()) {
      final installedDigest = await _installedDigest(target);
      if (installedDigest == actual) {
        await healthCheck(package.id, package.version);
        await _activate(package.id, package.version, actual);
        return target;
      }
      throw StateError('worker version is already installed');
    }

    await versionRoot.create(recursive: true);
    final staging = Directory(
      '${versionRoot.path}/.${package.version}.staging-'
      '${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await staging.create(recursive: true);
      await File('${staging.path}/package.bin')
          .writeAsBytes(package.bytes, flush: true);
      await File('${staging.path}/manifest.json').writeAsString(
        jsonEncode({
          ...manifest.toJson(),
          'digest': package.digest,
          if (package.signature != null) 'signature': package.signature,
        }),
        flush: true,
      );
      // A version directory is immutable once visible. Rename is the
      // activation point, so readers never observe a partially written one.
      await staging.rename(target.path);
    } catch (_) {
      if (await staging.exists()) await staging.delete(recursive: true);
      rethrow;
    }
    try {
      await healthCheck(package.id, package.version);
    } catch (_) {
      await target.delete(recursive: true);
      rethrow;
    }
    await _activate(package.id, package.version, actual);
    return target;
  }

  /// Confirms the immutable package is readable and internally consistent
  /// before its active pointer is changed.
  Future<void> healthCheck(String workerId, String version) async {
    final target = Directory('${root.path}/$workerId/$version');
    final packageFile = File('${target.path}/package.bin');
    if (!await packageFile.exists() || await packageFile.length() == 0) {
      throw StateError('worker health check failed: package is missing');
    }
    await _verifiedManifest(workerId, version);
  }

  Future<String?> _installedDigest(Directory target) async {
    final packageFile = File('${target.path}/package.bin');
    final manifestFile = File('${target.path}/manifest.json');
    if (!await packageFile.exists() || !await manifestFile.exists()) {
      return null;
    }
    final manifest = jsonDecode(await manifestFile.readAsString()) as Map;
    final digest = manifest['digest'];
    if (digest is! String || digest.isEmpty) return null;
    final actual = sha256.convert(await packageFile.readAsBytes()).toString();
    return _digestMatches(digest, actual) ? actual : null;
  }

  void _validatePathComponent(String value, String label) {
    if (value.isEmpty ||
        value == '.' ||
        value == '..' ||
        value.contains('/') ||
        value.contains('\\')) {
      throw StateError('$label must be a single path component');
    }
  }

  Future<String?> activeVersion(String workerId) async {
    _validatePathComponent(workerId, 'worker id');
    final file = File('${root.path}/$workerId/active.json');
    if (!await file.exists()) return null;
    final json = jsonDecode(await file.readAsString()) as Map;
    return json['version'] as String?;
  }

  Future<void> rollback(String workerId, String version) async {
    _validatePathComponent(workerId, 'worker id');
    _validatePathComponent(version, 'worker version');
    if (!await Directory('${root.path}/$workerId/$version').exists()) {
      throw StateError('worker version is not installed');
    }
    final manifestFile = File(
      '${root.path}/$workerId/$version/manifest.json',
    );
    if (!await manifestFile.exists()) {
      throw StateError('worker manifest is missing');
    }
    final manifest = await _verifiedManifest(workerId, version);
    await _activate(workerId, version, manifest['digest'] as String);
  }

  Future<void> deactivate(String workerId) async {
    _validatePathComponent(workerId, 'worker id');
    final activeFile = File('${root.path}/$workerId/active.json');
    if (await activeFile.exists()) await activeFile.delete();
  }

  Future<WorkerProcessSpec?> activeProcessSpec(String workerId) async {
    final version = await activeVersion(workerId);
    if (version == null) return null;
    final manifest = await _verifiedManifest(workerId, version);
    final executable = manifest['executable'];
    if (executable is! String || executable.isEmpty) {
      throw StateError('worker executable is missing');
    }
    // WorkerPackage currently stores one immutable executable payload. Do not
    // allow a mutable manifest to redirect execution to another local binary.
    if (executable != 'package.bin') {
      throw StateError(
          'worker executable must be the verified package payload');
    }
    final packageDirectory = Directory('${root.path}/$workerId/$version');
    final packageRoot = await packageDirectory.resolveSymbolicLinks();
    final executableFile = File('${packageDirectory.path}/package.bin');
    final executablePath = await executableFile.resolveSymbolicLinks();
    final containedPrefix = packageRoot.endsWith(Platform.pathSeparator)
        ? packageRoot
        : '$packageRoot${Platform.pathSeparator}';
    if (!executablePath.startsWith(containedPrefix)) {
      throw StateError('worker executable escapes its package directory');
    }
    final arguments = manifest['arguments'];
    return WorkerProcessSpec(
      workerId: workerId,
      executable: executablePath,
      arguments:
          arguments is List ? arguments.whereType<String>().toList() : const [],
      workingDirectory: '${root.path}/$workerId/$version',
      environment: _scopedSecretEnvironment(manifest),
      allowedEnvironmentVariables:
          _scopedSecretEnvironment(manifest).keys.toSet(),
      secretValues: _scopedSecretEnvironment(manifest).values.toSet(),
    );
  }

  void _validateSecretEnvironment(WorkerManifest manifest) {
    _validateSecretEnvironmentMap(manifest.toJson());
  }

  void _validateSecretEnvironmentMap(Map<String, Object?> manifest) {
    final names = manifest['secretEnvironmentVariables'];
    if (names is! List || names.isEmpty) return;
    final permissions = _permissionsFromManifest(manifest['permissions']);
    if (!permissions.contains(WorkerPermission.credentials)) {
      throw StateError(
          'worker secret environment requires credentials:read permission');
    }
    for (final name in names.whereType<String>()) {
      if (!RegExp(r'^[A-Z][A-Z0-9_]*$').hasMatch(name)) {
        throw StateError('invalid worker secret environment variable: $name');
      }
    }
  }

  Map<String, String> _scopedSecretEnvironment(Map<String, Object?> manifest) {
    final names = manifest['secretEnvironmentVariables'];
    if (names is! List) return const {};
    return {
      for (final name in names.whereType<String>())
        if (secretEnvironment.containsKey(name)) name: secretEnvironment[name]!,
    };
  }

  /// Re-check the immutable package payload before every process launch.
  /// Installation-time verification alone is insufficient because a local
  /// attacker or a broken updater could modify the package afterward.
  Future<Map<String, Object?>> _verifiedManifest(
    String workerId,
    String version,
  ) async {
    final directory = Directory('${root.path}/$workerId/$version');
    final manifestFile = File('${directory.path}/manifest.json');
    final packageFile = File('${directory.path}/package.bin');
    if (!await manifestFile.exists() || !await packageFile.exists()) {
      throw StateError('worker package is incomplete');
    }
    final manifest = Map<String, Object?>.from(
      jsonDecode(await manifestFile.readAsString()) as Map,
    );
    if (manifest['workerId'] != workerId || manifest['version'] != version) {
      throw StateError('worker manifest identity does not match installation');
    }
    if (manifest['protocolVersion'] != protocolVersion ||
        manifest['engineVersion'] is! String ||
        !_satisfiesMinimumVersion(
            engineVersion, manifest['engineVersion'] as String)) {
      throw StateError('worker is incompatible with this Host');
    }
    final supportedPlatforms = manifest['supportedPlatforms'];
    if (supportedPlatforms is List &&
        supportedPlatforms.isNotEmpty &&
        !supportedPlatforms.contains(platformKey) &&
        !supportedPlatforms.contains(platformKey.split('-').first)) {
      throw StateError('worker is not compatible with platform $platformKey');
    }
    final expectedDigest = manifest['digest'];
    if (expectedDigest is! String || expectedDigest.isEmpty) {
      throw StateError('worker package digest is missing');
    }
    final actualDigest =
        sha256.convert(await packageFile.readAsBytes()).toString();
    if (!_digestMatches(expectedDigest, actualDigest)) {
      throw StateError('worker package was modified after installation');
    }
    final policy = trustPolicy;
    if (requireSignature && policy == null) {
      throw StateError('worker signature verification is not configured');
    }
    _requirePermissions(_permissionsFromManifest(manifest['permissions']));
    _validateSecretEnvironmentMap(manifest);
    if (policy != null) {
      final publisher = manifest['publisher'];
      final signature = manifest['signature'];
      if (publisher is! String ||
          signature is! String ||
          !policy.verify(
            publisher: publisher,
            digest: expectedDigest,
            signature: signature,
          )) {
        throw StateError('worker signing trust has been revoked');
      }
      policy.requirePermissions(
        _permissionsFromManifest(manifest['permissions']),
        allowedPermissions,
      );
    }
    return manifest;
  }

  bool _digestMatches(String expected, String actual) =>
      expected == actual || expected == 'sha256:$actual';

  void _requirePermissions(Iterable<WorkerPermission> permissions) {
    const policy = WorkerTrustPolicy();
    policy.requirePermissions(permissions, allowedPermissions);
  }

  List<WorkerPermission> _permissionsFromManifest(Object? raw) {
    if (raw is! List) return const [];
    return raw.whereType<String>().map(parseWorkerPermission).toList();
  }

  Future<List<InstalledWorker>> inventory() async {
    if (!await root.exists()) return [];
    final result = <InstalledWorker>[];
    await for (final workerEntity in root.list(followLinks: false)) {
      if (workerEntity is! Directory) continue;
      final workerId = workerEntity.path.split(Platform.pathSeparator).last;
      final active = await activeVersion(workerId);
      await for (final versionEntity in workerEntity.list(followLinks: false)) {
        if (versionEntity is! Directory) continue;
        final version = versionEntity.path.split(Platform.pathSeparator).last;
        final manifestFile = File('${versionEntity.path}/manifest.json');
        if (!await manifestFile.exists()) continue;
        final manifest = Map<String, Object?>.from(
          jsonDecode(await manifestFile.readAsString()) as Map,
        );
        final digest = manifest['digest'];
        if (digest is! String) continue;
        result.add(InstalledWorker(
          workerId: workerId,
          version: version,
          digest: digest,
          active: active == version,
          manifest: manifest,
        ));
      }
    }
    return result;
  }

  Future<void> remove(String workerId, String version) async {
    _validatePathComponent(workerId, 'worker id');
    _validatePathComponent(version, 'worker version');
    if (await activeVersion(workerId) == version) {
      throw StateError('cannot remove the active worker version');
    }
    final target = Directory('${root.path}/$workerId/$version');
    if (await target.exists()) await target.delete(recursive: true);
  }

  /// Removes inactive versions that Cloud no longer requests.
  Future<void> garbageCollect(
      {Map<String, String> keepVersions = const {}}) async {
    if (!await root.exists()) return;
    await for (final workerEntity in root.list(followLinks: false)) {
      if (workerEntity is! Directory) continue;
      final workerId = workerEntity.path.split(Platform.pathSeparator).last;
      final active = await activeVersion(workerId);
      await for (final versionEntity in workerEntity.list(followLinks: false)) {
        if (versionEntity is! Directory) continue;
        final version = versionEntity.path.split(Platform.pathSeparator).last;
        if (version == active || keepVersions[workerId] == version) continue;
        await versionEntity.delete(recursive: true);
      }
    }
  }

  WorkerAssignmentHandler assignmentHandler(
    WorkerProcessExecutor executor, {
    Future<String?> Function(String repositoryId)? resolveRepositoryPath,
  }) =>
      WorkerAssignmentHandler(
        executor: executor,
        resolve: activeProcessSpec,
        resolveRepositoryPath: resolveRepositoryPath,
      );

  Future<void> _activate(
      String workerId, String version, String? digest) async {
    final activeFile = File('${root.path}/$workerId/active.json');
    final temporaryFile =
        File('${activeFile.path}.tmp-${DateTime.now().microsecondsSinceEpoch}');
    await temporaryFile.writeAsString(
      jsonEncode({'version': version, if (digest != null) 'digest': digest}),
      flush: true,
    );
    await temporaryFile.rename(activeFile.path);
  }

  bool _satisfiesMinimumVersion(String current, String requirement) {
    final minimum =
        requirement.startsWith('>=') ? requirement.substring(2) : requirement;
    final currentParts = _versionParts(current);
    final minimumParts = _versionParts(minimum);
    for (var index = 0; index < 3; index++) {
      if (currentParts[index] != minimumParts[index]) {
        return currentParts[index] > minimumParts[index];
      }
    }
    return true;
  }

  List<int> _versionParts(String version) => version
      .split('.')
      .take(3)
      .map((part) => int.tryParse(part.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
      .followedBy(const [0, 0, 0])
      .take(3)
      .toList();
}
