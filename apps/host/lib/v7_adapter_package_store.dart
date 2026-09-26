import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import 'configured_worker_registry.dart';
import 'v7_adapter_admission.dart';
import 'worker_executor.dart';
import 'worker_trust_policy.dart';

/// Installs immutable, pre-extracted V7 adapter packages under the Workspace
/// data directory. The package digest is the SHA-256 of the sorted file tree,
/// excluding only the root manifest.json to avoid a signature cycle.
class V7AdapterPackageStore {
  V7AdapterPackageStore({
    required this.root,
    required this.trustPolicy,
    required this.allowedPermissions,
    WorkerProcessExecutor? executor,
    String? platform,
    this.maxPackageBytes = 512 * 1024 * 1024,
  })  : platform = platform ?? _currentPlatform(),
        executor = executor ?? WorkerProcessExecutor();

  final Directory root;
  final WorkerTrustPolicy trustPolicy;
  final Set<WorkerPermission> allowedPermissions;
  final WorkerProcessExecutor executor;
  final String platform;
  final int maxPackageBytes;

  /// Extracts a Cloud-delivered gzip-compressed tar package into a private
  /// staging directory, rejects links and unsafe/duplicate paths, then applies
  /// the normal digest, signature, permission, and health checks before the
  /// package can become active.
  Future<Directory> installArchive({
    required List<int> archiveBytes,
    Map<String, Object?>? expectedManifest,
  }) async {
    if (archiveBytes.isEmpty || archiveBytes.length > maxPackageBytes) {
      throw StateError('adapter archive is empty or exceeds size limit');
    }
    final archiveRoot = await root.create(recursive: true);
    final staging = await archiveRoot.createTemp('.v7-archive-');
    try {
      final tarBuilder = BytesBuilder(copy: false);
      var tarLength = 0;
      await for (final chunk in gzip.decoder.bind(
        Stream<List<int>>.value(archiveBytes),
      )) {
        tarLength += chunk.length;
        if (tarLength > maxPackageBytes) {
          throw StateError('expanded adapter archive exceeds size limit');
        }
        tarBuilder.add(chunk);
      }
      final tarBytes = tarBuilder.takeBytes();
      final entries = TarDecoder().decodeBytes(tarBytes, verify: true);
      if (entries.length > 10000) {
        throw StateError('adapter archive contains too many entries');
      }
      final seen = <String>{};
      var expandedBytes = 0;
      for (final entry in entries) {
        final relative = _safeArchivePath(entry.name);
        if (!seen.add(relative)) {
          throw StateError('adapter archive contains duplicate paths');
        }
        if (entry.isSymbolicLink) {
          throw StateError('adapter archives cannot contain symlinks');
        }
        final output = File('${staging.path}${Platform.pathSeparator}'
            '${relative.replaceAll('/', Platform.pathSeparator)}');
        if (entry.isDirectory) {
          await Directory(output.path).create(recursive: true);
          continue;
        }
        expandedBytes += entry.size;
        if (expandedBytes > maxPackageBytes) {
          throw StateError('expanded adapter archive exceeds size limit');
        }
        await output.parent.create(recursive: true);
        final contents = entry.readBytes();
        if (contents == null || contents.length != entry.size) {
          throw StateError('adapter archive contains a truncated file');
        }
        await output.writeAsBytes(contents, flush: true);
        if (!Platform.isWindows && (entry.unixPermissions & 0x49) != 0) {
          final result = await Process.run('chmod', [
            (entry.unixPermissions & 0x1ff).toRadixString(8),
            output.path,
          ]);
          if (result.exitCode != 0) {
            throw StateError('could not preserve adapter executable mode');
          }
        }
      }
      final manifestFile =
          File('${staging.path}${Platform.pathSeparator}manifest.json');
      if (!await manifestFile.exists()) {
        throw StateError('V7 adapter archive must contain root manifest.json');
      }
      if (expectedManifest != null) {
        final archiveManifest = jsonDecode(await manifestFile.readAsString());
        if (archiveManifest is! Map ||
            _canonicalJson(Map<String, Object?>.from(archiveManifest)) !=
                _canonicalJson(expectedManifest)) {
          throw StateError(
              'downloaded adapter manifest does not match its catalog release');
        }
      }
      return await install(sourceDirectory: staging);
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }

  String _safeArchivePath(String path) {
    if (path.isEmpty ||
        path.startsWith('/') ||
        path.startsWith('\\') ||
        path.contains('\\') ||
        RegExp(r'^[A-Za-z]:').hasMatch(path)) {
      throw StateError('adapter archive contains an invalid path');
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
      throw StateError('adapter archive contains an invalid path');
    }
    return parts.join('/');
  }

  Future<Directory> install({required Directory sourceDirectory}) async {
    final sourceRoot = await sourceDirectory.resolveSymbolicLinks();
    final manifestFile =
        File('$sourceRoot${Platform.pathSeparator}manifest.json');
    if (!await manifestFile.exists()) {
      throw StateError('V7 adapter package manifest is missing');
    }
    final rawManifest = jsonDecode(await manifestFile.readAsString());
    if (rawManifest is! Map) {
      throw const FormatException('V7 adapter package manifest is invalid');
    }
    final manifest = Map<String, Object?>.from(rawManifest);
    final workerTypeId = _safeTypeId(manifest['workerTypeId']);
    final adapterVersion = _safeVersion(manifest['adapterVersion']);
    final digest = await digestDirectory(Directory(sourceRoot));
    final admitted = await V7AdapterAdmission.admit(
      input: manifest,
      packageRoot: Directory(sourceRoot),
      expectedWorkerTypeId: workerTypeId,
      verifiedPackageDigest: digest,
      platform: platform,
      trustPolicy: trustPolicy,
      allowedPermissions: allowedPermissions,
    );
    final typeRoot =
        Directory('${root.path}${Platform.pathSeparator}$workerTypeId');
    final target =
        Directory('${typeRoot.path}${Platform.pathSeparator}$adapterVersion');
    await typeRoot.create(recursive: true);
    if (await target.exists()) {
      final existingDigest = await digestDirectory(target);
      if (existingDigest != digest) {
        throw StateError(
            'adapter version is already installed with different contents');
      }
      final existingManifest = Map<String, Object?>.from(
        jsonDecode(
            await File('${target.path}${Platform.pathSeparator}manifest.json')
                .readAsString()) as Map,
      );
      final existingAdmission = await V7AdapterAdmission.admit(
        input: existingManifest,
        packageRoot: target,
        expectedWorkerTypeId: workerTypeId,
        verifiedPackageDigest: existingDigest,
        platform: platform,
        trustPolicy: trustPolicy,
        allowedPermissions: allowedPermissions,
      );
      await _healthCheck(target, existingAdmission);
      await _activate(typeRoot, adapterVersion);
      return target;
    }
    final staging = Directory(
        '${typeRoot.path}${Platform.pathSeparator}.$adapterVersion.staging-${DateTime.now().microsecondsSinceEpoch}');
    try {
      await _copyTree(Directory(sourceRoot), staging);
      final copiedDigest = await digestDirectory(staging);
      if (copiedDigest != digest) {
        throw StateError('adapter package changed during install');
      }
      final stagedAdmission = await V7AdapterAdmission.admit(
        input: manifest,
        packageRoot: staging,
        expectedWorkerTypeId: workerTypeId,
        verifiedPackageDigest: copiedDigest,
        platform: platform,
        trustPolicy: trustPolicy,
        allowedPermissions: allowedPermissions,
      );
      await _healthCheck(staging, stagedAdmission);
      await staging.rename(target.path);
    } catch (_) {
      if (await staging.exists()) await staging.delete(recursive: true);
      rethrow;
    }
    if (admitted.adapterVersion != adapterVersion) {
      await target.delete(recursive: true);
      throw StateError('adapter version changed during admission');
    }
    await _activate(typeRoot, adapterVersion);
    return target;
  }

  /// Re-verifies and health-checks an installed release before making it
  /// active. The old pointer remains live until the atomic replacement.
  Future<void> rollback({
    required String workerTypeId,
    required String version,
  }) async {
    _safeTypeId(workerTypeId);
    _safeVersion(version);
    final packageRoot = Directory(
        '${root.path}${Platform.pathSeparator}$workerTypeId${Platform.pathSeparator}$version');
    final manifestFile =
        File('${packageRoot.path}${Platform.pathSeparator}manifest.json');
    if (!await manifestFile.exists()) {
      throw StateError('adapter version is not installed');
    }
    final manifest = Map<String, Object?>.from(
      jsonDecode(await manifestFile.readAsString()) as Map,
    );
    final digest = await digestDirectory(packageRoot);
    final admitted = await V7AdapterAdmission.admit(
      input: manifest,
      packageRoot: packageRoot,
      expectedWorkerTypeId: workerTypeId,
      verifiedPackageDigest: digest,
      platform: platform,
      trustPolicy: trustPolicy,
      allowedPermissions: allowedPermissions,
    );
    await _healthCheck(packageRoot, admitted);
    await _activate(
      Directory('${root.path}${Platform.pathSeparator}$workerTypeId'),
      version,
    );
  }

  /// Restores the last previously active adapter only after independently
  /// rechecking its current signature, digest, permissions, platform and health.
  Future<bool> restoreLastHealthyVersion(String workerTypeId) async {
    _safeTypeId(workerTypeId);
    final typeRoot =
        Directory('${root.path}${Platform.pathSeparator}$workerTypeId');
    final rollbackFile =
        File('${typeRoot.path}${Platform.pathSeparator}last-healthy.json');
    if (!await rollbackFile.exists()) return false;
    try {
      final pointer = jsonDecode(await rollbackFile.readAsString());
      if (pointer is! Map || pointer['version'] is! String) return false;
      final version = _safeVersion(pointer['version']);
      final packageRoot =
          Directory('${typeRoot.path}${Platform.pathSeparator}$version');
      final manifestFile =
          File('${packageRoot.path}${Platform.pathSeparator}manifest.json');
      final rawManifest = jsonDecode(await manifestFile.readAsString());
      if (rawManifest is! Map) return false;
      final manifest = Map<String, Object?>.from(rawManifest);
      final digest = await digestDirectory(packageRoot);
      final admitted = await V7AdapterAdmission.admit(
        input: manifest,
        packageRoot: packageRoot,
        expectedWorkerTypeId: workerTypeId,
        verifiedPackageDigest: digest,
        platform: platform,
        trustPolicy: trustPolicy,
        allowedPermissions: allowedPermissions,
      );
      await _healthCheck(packageRoot, admitted);
      await _activate(typeRoot, version, rememberPrevious: false);
      return true;
    } on Object {
      return false;
    }
  }

  Future<V7AdapterLaunch?> resolve({
    required LocalConfiguredWorker worker,
    required SecureCredentialReader readCredential,
  }) async {
    final activeFile = File(
        '${root.path}${Platform.pathSeparator}${worker.workerTypeId}${Platform.pathSeparator}active.json');
    if (!await activeFile.exists()) return null;
    final rawPointer = jsonDecode(await activeFile.readAsString());
    if (rawPointer is! Map || rawPointer['version'] is! String) {
      throw const FormatException('active V7 adapter pointer is invalid');
    }
    final version = _safeVersion(rawPointer['version']);
    if (worker.adapterVersionPolicy != null &&
        worker.adapterVersionPolicy != 'stable' &&
        worker.adapterVersionPolicy != version) {
      throw StateError(
          'installed adapter does not satisfy the local version policy');
    }
    final packageRoot = Directory(
        '${root.path}${Platform.pathSeparator}${worker.workerTypeId}${Platform.pathSeparator}$version');
    final manifestFile =
        File('${packageRoot.path}${Platform.pathSeparator}manifest.json');
    if (!await manifestFile.exists()) {
      throw StateError('installed adapter manifest is missing');
    }
    final rawManifest = jsonDecode(await manifestFile.readAsString());
    final manifest = Map<String, Object?>.from(rawManifest as Map);
    final digest = await digestDirectory(packageRoot);
    final admitted = await V7AdapterAdmission.admit(
      input: manifest,
      packageRoot: packageRoot,
      expectedWorkerTypeId: worker.workerTypeId,
      verifiedPackageDigest: digest,
      platform: platform,
      trustPolicy: trustPolicy,
      allowedPermissions: allowedPermissions,
    );
    trustPolicy.requirePermissions(
      admitted.permissions,
      _workerPermissions(worker.localPermissions),
    );
    if (admitted.adapterVersion != version) {
      throw StateError('active adapter version does not match its manifest');
    }
    final releaseChannel = manifest['releaseChannel'];
    if ((worker.adapterVersionPolicy == 'stable' &&
            releaseChannel != 'stable') ||
        (worker.adapterVersionPolicy == 'beta' &&
            !const {'stable', 'beta'}.contains(releaseChannel))) {
      throw StateError(
          'installed adapter does not satisfy the release channel policy');
    }
    final secrets = <String, String>{};
    if (worker.credentialRef != null) {
      final credential = readCredential(worker.credentialRef!);
      if (credential != null && credential.isNotEmpty) {
        for (final requirement in admitted.secretRequirements) {
          if (requirement.authStrategy == worker.authStrategy) {
            secrets[requirement.name] = credential;
          }
        }
      }
    }
    final spec = admitted.createProcessSpec(
      workerId: worker.id,
      workingDirectory: packageRoot.path,
      localConcurrencyLimit: worker.localConcurrencyLimit,
      availableSecrets: secrets,
    );
    return V7AdapterLaunch(
      processSpec: spec,
      workerTypeId: worker.workerTypeId,
      adapterVersion: admitted.adapterVersion,
      config: Map.unmodifiable(worker.adapterConfig),
      defaultModel: worker.defaultModel,
      allowedModels: worker.allowedModels.toSet(),
    );
  }

  /// Returns only signed, digest-verified public adapter metadata for safe
  /// inventory synchronization. Invalid or revoked packages never contribute
  /// a version or capabilities to the Cloud projection.
  Future<Map<String, Object?>?> activeManifestSummary(
      LocalConfiguredWorker worker) async {
    final activeFile = File(
        '${root.path}${Platform.pathSeparator}${worker.workerTypeId}${Platform.pathSeparator}active.json');
    if (!await activeFile.exists()) return null;
    final rawPointer = jsonDecode(await activeFile.readAsString());
    if (rawPointer is! Map || rawPointer['version'] is! String) {
      throw const FormatException('active V7 adapter pointer is invalid');
    }
    final version = _safeVersion(rawPointer['version']);
    final packageRoot = Directory(
        '${root.path}${Platform.pathSeparator}${worker.workerTypeId}${Platform.pathSeparator}$version');
    final manifestFile =
        File('${packageRoot.path}${Platform.pathSeparator}manifest.json');
    if (!await manifestFile.exists()) return null;
    final rawManifest = jsonDecode(await manifestFile.readAsString());
    if (rawManifest is! Map) {
      throw const FormatException('active V7 adapter manifest is invalid');
    }
    final manifest = Map<String, Object?>.from(rawManifest);
    final digest = await digestDirectory(packageRoot);
    final admitted = await V7AdapterAdmission.admit(
      input: manifest,
      packageRoot: packageRoot,
      expectedWorkerTypeId: worker.workerTypeId,
      verifiedPackageDigest: digest,
      platform: platform,
      trustPolicy: trustPolicy,
      allowedPermissions: allowedPermissions,
    );
    trustPolicy.requirePermissions(
        admitted.permissions, _workerPermissions(worker.localPermissions));
    if (admitted.adapterVersion != version) {
      throw StateError('active adapter version does not match its manifest');
    }
    final capabilities = manifest['capabilities'];
    if (capabilities is! List ||
        capabilities.any((value) => value is! String)) {
      throw const FormatException('active V7 adapter capabilities are invalid');
    }
    return {
      'adapterVersion': version,
      'capabilities': List<String>.unmodifiable(capabilities.cast<String>()),
    };
  }

  /// Uses the admitted provider adapter to check an API credential without
  /// generating model output. The key is passed only through the adapter's
  /// declared scoped process environment.
  Future<List<String>> validateApiCredential({
    required String workerTypeId,
    required String apiKey,
    required String endpointUrl,
    required List<String> localPermissions,
  }) async {
    if (!const {'openai-api', 'gemini-api', 'anthropic-api', 'ollama'}
            .contains(workerTypeId) ||
        (workerTypeId != 'ollama' && apiKey.isEmpty)) {
      throw ArgumentError('API Worker credential validation input is invalid.');
    }
    final activeFile = File(
        '${root.path}${Platform.pathSeparator}$workerTypeId${Platform.pathSeparator}active.json');
    if (!await activeFile.exists()) {
      throw StateError('A trusted API adapter must be installed first.');
    }
    final pointer = jsonDecode(await activeFile.readAsString());
    if (pointer is! Map || pointer['version'] is! String) {
      throw const FormatException('active V7 adapter pointer is invalid');
    }
    final version = _safeVersion(pointer['version']);
    final packageRoot = Directory(
        '${root.path}${Platform.pathSeparator}$workerTypeId${Platform.pathSeparator}$version');
    final manifestFile =
        File('${packageRoot.path}${Platform.pathSeparator}manifest.json');
    final rawManifest = jsonDecode(await manifestFile.readAsString());
    if (rawManifest is! Map) {
      throw const FormatException('active V7 adapter manifest is invalid');
    }
    final manifest = Map<String, Object?>.from(rawManifest);
    final digest = await digestDirectory(packageRoot);
    final admitted = await V7AdapterAdmission.admit(
      input: manifest,
      packageRoot: packageRoot,
      expectedWorkerTypeId: workerTypeId,
      verifiedPackageDigest: digest,
      platform: platform,
      trustPolicy: trustPolicy,
      allowedPermissions: allowedPermissions,
    );
    trustPolicy.requirePermissions(
        admitted.permissions, _workerPermissions(localPermissions));
    final secrets = <String, String>{};
    for (final requirement in admitted.secretRequirements) {
      if (requirement.authStrategy == 'api_key') {
        secrets[requirement.name] = apiKey;
      }
    }
    final spec = admitted.createProcessSpec(
      workerId: 'setup-validation:$workerTypeId',
      workingDirectory: packageRoot.path,
      localConcurrencyLimit: 1,
      availableSecrets: secrets,
    );
    final result = await executor.executeV7Adapter(
      spec,
      workerTypeId: workerTypeId,
      adapterVersion: admitted.adapterVersion,
      prompt: '',
      config: {
        if (endpointUrl.trim().isNotEmpty) 'endpointUrl': endpointUrl.trim(),
      },
      validateOnly: true,
      operationId:
          'setup-validation:$workerTypeId:${DateTime.now().microsecondsSinceEpoch}',
      timeout: const Duration(seconds: 20),
    );
    return List<String>.from(result['models'] as List? ?? const []);
  }

  /// Returns true only when the active package still passes digest, signature,
  /// platform, permission, and protocol health admission checks.
  Future<bool> hasVerifiedActivePackage(String workerTypeId,
      [List<String>? localPermissions]) async {
    try {
      _safeTypeId(workerTypeId);
      final pointer = File(
          '${root.path}${Platform.pathSeparator}$workerTypeId${Platform.pathSeparator}active.json');
      if (!await pointer.exists()) return false;
      final value = jsonDecode(await pointer.readAsString());
      if (value is! Map || value['version'] is! String) return false;
      final version = _safeVersion(value['version']);
      final packageRoot = Directory(
          '${root.path}${Platform.pathSeparator}$workerTypeId${Platform.pathSeparator}$version');
      final manifestFile =
          File('${packageRoot.path}${Platform.pathSeparator}manifest.json');
      if (!await manifestFile.exists()) return false;
      final manifest = jsonDecode(await manifestFile.readAsString());
      if (manifest is! Map) return false;
      final digest = await digestDirectory(packageRoot);
      final admitted = await V7AdapterAdmission.admit(
        input: Map<String, Object?>.from(manifest),
        packageRoot: packageRoot,
        expectedWorkerTypeId: workerTypeId,
        verifiedPackageDigest: digest,
        platform: platform,
        trustPolicy: trustPolicy,
        allowedPermissions: allowedPermissions,
      );
      if (localPermissions != null) {
        trustPolicy.requirePermissions(
          admitted.permissions,
          _workerPermissions(localPermissions),
        );
      }
      await _healthCheck(packageRoot, admitted);
      return admitted.adapterVersion == version;
    } on Object {
      return false;
    }
  }

  Future<String> digestDirectory(Directory directory) async {
    final rootPath = await directory.resolveSymbolicLinks();
    final files = <(String, File, int)>[];
    var totalBytes = 0;
    await for (final entity
        in Directory(rootPath).list(recursive: true, followLinks: false)) {
      if (entity is Link) {
        throw StateError('adapter packages cannot contain symlinks');
      }
      if (entity is! File) continue;
      final relative = entity.path
          .substring(rootPath.length + 1)
          .replaceAll(Platform.pathSeparator, '/');
      if (relative
          .split('/')
          .any((part) => part.isEmpty || part == '.' || part == '..')) {
        throw StateError('adapter package contains an invalid path');
      }
      if (relative == 'manifest.json') continue;
      totalBytes += await entity.length();
      if (totalBytes > maxPackageBytes) {
        throw StateError('adapter package exceeds size limit');
      }
      final mode =
          Platform.isWindows ? 0x1ff : (await entity.stat()).mode & 0x1ff;
      files.add((relative, entity, mode));
      if (files.length > 10000) {
        throw StateError('adapter package contains too many files');
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

  Future<void> _copyTree(Directory source, Directory target) async {
    await target.create(recursive: true);
    final sourceRoot = await source.resolveSymbolicLinks();
    await for (final entity
        in Directory(sourceRoot).list(recursive: true, followLinks: false)) {
      if (entity is Link) {
        throw StateError('adapter packages cannot contain symlinks');
      }
      final relative = entity.path.substring(sourceRoot.length + 1);
      final destination = '${target.path}${Platform.pathSeparator}$relative';
      if (entity is Directory) {
        await Directory(destination).create(recursive: true);
      } else if (entity is File) {
        final parent = File(destination).parent;
        await parent.create(recursive: true);
        await entity.copy(destination);
      }
    }
  }

  Future<void> _healthCheck(
    Directory packageRoot,
    V7AdapterAdmission admitted,
  ) async {
    await executor.checkV7AdapterHealth(
      WorkerProcessSpec(
        workerId: 'adapter-health:${admitted.workerTypeId}',
        executable: admitted.executable.path,
        arguments: admitted.launchArgs,
        workingDirectory: packageRoot.path,
      ),
      workerTypeId: admitted.workerTypeId,
      adapterVersion: admitted.adapterVersion,
      healthCheckMode: admitted.healthCheckMode,
      timeout: Duration(milliseconds: admitted.healthCheckTimeoutMs),
    );
  }

  Future<void> _activate(Directory typeRoot, String version,
      {bool rememberPrevious = true}) async {
    final target = File('${typeRoot.path}${Platform.pathSeparator}active.json');
    final rollback =
        File('${typeRoot.path}${Platform.pathSeparator}last-healthy.json');
    if (rememberPrevious && await target.exists()) {
      try {
        final current = jsonDecode(await target.readAsString());
        if (current is Map &&
            current['version'] is String &&
            current['version'] != version) {
          final previousVersion = _safeVersion(current['version']);
          final previousRoot = Directory(
              '${typeRoot.path}${Platform.pathSeparator}$previousVersion');
          final manifestFile = File(
              '${previousRoot.path}${Platform.pathSeparator}manifest.json');
          final manifestValue = jsonDecode(await manifestFile.readAsString());
          if (manifestValue is Map) {
            final manifest = Map<String, Object?>.from(manifestValue);
            final digest = await digestDirectory(previousRoot);
            final admitted = await V7AdapterAdmission.admit(
              input: manifest,
              packageRoot: previousRoot,
              expectedWorkerTypeId:
                  typeRoot.path.split(Platform.pathSeparator).last,
              verifiedPackageDigest: digest,
              platform: platform,
              trustPolicy: trustPolicy,
              allowedPermissions: allowedPermissions,
            );
            await _healthCheck(previousRoot, admitted);
            await rollback.writeAsString(
                jsonEncode({'version': previousVersion}),
                flush: true);
          }
        }
      } on Object {
        // A failed old version is not a rollback candidate.
      }
    }
    final temporary = File(
        '${typeRoot.path}${Platform.pathSeparator}.active-${DateTime.now().microsecondsSinceEpoch}.tmp');
    await temporary.writeAsString(jsonEncode({'version': version}),
        flush: true);
    await temporary.rename(target.path);
  }

  String _safeTypeId(Object? value) {
    if (value is! String ||
        !RegExp(r'^[a-z0-9][a-z0-9._-]*$').hasMatch(value)) {
      throw const FormatException('adapter Worker Type ID is invalid');
    }
    return value;
  }

  String _safeVersion(Object? value) {
    if (value is! String ||
        !RegExp(r'^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$')
            .hasMatch(value)) {
      throw const FormatException('adapter version is invalid');
    }
    return value;
  }

  static String _currentPlatform() {
    final os = switch (Platform.operatingSystem) {
      'macos' => 'macos',
      'linux' => 'linux',
      'windows' => 'windows',
      _ => Platform.operatingSystem,
    };
    final arch =
        Platform.version.toLowerCase().contains('arm64') ? 'arm64' : 'x64';
    return '$os-$arch';
  }

  Set<WorkerPermission> _workerPermissions(List<String> localPermissions) {
    final result = <WorkerPermission>{};
    for (final permission in localPermissions) {
      switch (permission) {
        case 'repository:read':
          result.add(WorkerPermission.readWorkspace);
          break;
        case 'repository:write':
          result.add(WorkerPermission.writeWorkspace);
          break;
        case 'workstream_filesystem':
          result
            ..add(WorkerPermission.readWorkspace)
            ..add(WorkerPermission.writeWorkspace);
          break;
        case 'shell_execution':
          result.add(WorkerPermission.shell);
          break;
        case 'network':
          result.add(WorkerPermission.network);
          result
            ..add(WorkerPermission.networkOpenAi)
            ..add(WorkerPermission.networkGoogle)
            ..add(WorkerPermission.networkAnthropic);
          break;
        case 'network_openai':
          result.add(WorkerPermission.networkOpenAi);
          break;
        case 'network_google':
          result.add(WorkerPermission.networkGoogle);
          break;
        case 'network_anthropic':
          result.add(WorkerPermission.networkAnthropic);
          break;
        default:
          result.add(parseWorkerPermission(permission));
      }
    }
    return result;
  }
}

String _canonicalJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return '{${keys.map((key) => '${jsonEncode(key)}:${_canonicalJson(value[key])}').join(',')}}';
  }
  if (value is List) return '[${value.map(_canonicalJson).join(',')}]';
  return jsonEncode(value);
}

typedef SecureCredentialReader = String? Function(String key);
