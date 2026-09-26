import 'dart:io';

import 'adapter_prerequisite.dart';
import 'worker_executor.dart';
import 'worker_trust_policy.dart';

/// A v7 adapter manifest admitted against the local machine's trust boundary.
/// The caller must verify the downloaded package digest before constructing it.
class V7AdapterAdmission {
  V7AdapterAdmission._({
    required this.workerTypeId,
    required this.adapterVersion,
    required this.protocolVersion,
    required this.publisher,
    required this.executable,
    required this.launchArgs,
    required this.permissions,
    required this.secretRequirements,
    required this.healthCheckMode,
    required this.healthCheckTimeoutMs,
  });

  final String workerTypeId;
  final String adapterVersion;
  final String protocolVersion;
  final String publisher;
  final File executable;
  final List<String> launchArgs;
  final Set<WorkerPermission> permissions;
  final List<V7AdapterSecretRequirement> secretRequirements;
  final String healthCheckMode;
  final int healthCheckTimeoutMs;

  static Future<V7AdapterAdmission> admit({
    required Object? input,
    required Directory packageRoot,
    required String expectedWorkerTypeId,
    required String verifiedPackageDigest,
    required String platform,
    required WorkerTrustPolicy trustPolicy,
    required Set<WorkerPermission> allowedPermissions,
  }) async {
    final value = _object(input, 'manifest');
    const fields = {
      'workerTypeId',
      'adapterVersion',
      'protocolVersion',
      'publisher',
      'displayName',
      'supportedPlatforms',
      'capabilities',
      'permissions',
      'authStrategies',
      'modelSelectionMode',
      'prerequisites',
      'executable',
      'launchArgs',
      'secretRequirements',
      'healthCheck',
      'packageDigest',
      'signingKeyId',
      'signature',
      'releaseChannel',
    };
    if (value.keys.any((key) => !fields.contains(key)) ||
        fields.any((key) => !value.containsKey(key))) {
      throw const FormatException('adapter manifest fields are invalid');
    }
    String text(String key) {
      final result = value[key];
      if (result is! String || result.trim().isEmpty) {
        throw FormatException('$key must be a non-empty string');
      }
      return result.trim();
    }

    final workerTypeId = text('workerTypeId');
    final version = text('adapterVersion');
    final protocolVersion = text('protocolVersion');
    final publisher = text('publisher');
    text('displayName');
    final digest = text('packageDigest').toLowerCase();
    final signature = text('signature');
    final signingKeyId = text('signingKeyId');
    if (workerTypeId != expectedWorkerTypeId ||
        !RegExp(r'^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$')
            .hasMatch(version) ||
        protocolVersion != '1.0' ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) ||
        digest != verifiedPackageDigest.toLowerCase()) {
      throw const FormatException(
          'adapter identity or package digest mismatch');
    }
    if (!await trustPolicy.verifyAdapterManifest(
      publisher: publisher,
      signingKeyId: signingKeyId,
      digest: digest,
      signature: signature,
      manifest: value,
    )) {
      throw StateError('adapter publisher signature is not trusted');
    }
    final supported =
        _strings(value['supportedPlatforms'], 'supportedPlatforms');
    if (!supported.contains(platform)) {
      throw StateError('adapter does not support this platform');
    }
    final declaredPermissions = _strings(value['permissions'], 'permissions')
        .map(parseWorkerPermission)
        .toSet();
    trustPolicy.requirePermissions(declaredPermissions, allowedPermissions);
    _strings(value['capabilities'], 'capabilities');
    final authStrategies = _strings(value['authStrategies'], 'authStrategies');
    if (authStrategies.isEmpty ||
        authStrategies.any((strategy) => !const {
              'none',
              'browser_auth',
              'api_key',
              'local_endpoint'
            }.contains(strategy))) {
      throw const FormatException('adapter auth strategies are invalid');
    }
    if (!const {'fixed', 'allow_list', 'automatic'}
        .contains(value['modelSelectionMode'])) {
      throw const FormatException('adapter model selection mode is invalid');
    }
    final prerequisites = _list(value['prerequisites'], 'prerequisites');
    if (prerequisites.length > 32) {
      throw const FormatException('adapter has too many prerequisites');
    }
    for (final prerequisite in prerequisites) {
      AdapterExecutablePrerequisite.fromJson(prerequisite);
    }
    final health = _object(value['healthCheck'], 'healthCheck');
    if (!const {'protocol', 'process_exit'}.contains(health['mode']) ||
        health['timeoutMs'] is! int ||
        (health['timeoutMs'] as int) < 100 ||
        (health['timeoutMs'] as int) > 30000) {
      throw const FormatException('adapter health check is invalid');
    }
    if (!const {'stable', 'beta', 'development'}
        .contains(value['releaseChannel'])) {
      throw const FormatException('adapter release channel is invalid');
    }
    final relativeExecutable = text('executable');
    if (relativeExecutable.contains('\\') ||
        relativeExecutable.startsWith('/') ||
        RegExp(r'^[A-Za-z]:').hasMatch(relativeExecutable) ||
        relativeExecutable
            .split('/')
            .any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw const FormatException('adapter executable escapes its package');
    }
    final root = await packageRoot.resolveSymbolicLinks();
    final candidate = File(
        '$root${Platform.pathSeparator}${relativeExecutable.replaceAll('/', Platform.pathSeparator)}');
    final resolved = await candidate.resolveSymbolicLinks();
    if (!resolved.startsWith('$root${Platform.pathSeparator}') ||
        !await FileSystemEntity.isFile(resolved)) {
      throw const FormatException(
          'adapter executable resolves outside its package');
    }
    final launchArgs = _strings(value['launchArgs'], 'launchArgs');
    if (launchArgs.length > 64 || launchArgs.any((arg) => arg.length > 2048)) {
      throw const FormatException('adapter launch arguments exceed limits');
    }
    final secrets = <V7AdapterSecretRequirement>[];
    final secretNames = <String>{};
    final environmentNames = <String>{};
    for (final raw
        in _list(value['secretRequirements'], 'secretRequirements')) {
      final item = _object(raw, 'secret requirement');
      const secretFields = {
        'name',
        'authStrategy',
        'environmentVariable',
        'required',
        'description'
      };
      if (item.keys.any((key) => !secretFields.contains(key)) ||
          secretFields.any((key) => !item.containsKey(key))) {
        throw const FormatException('secret requirement fields are invalid');
      }
      final name = item['name'];
      final envName = item['environmentVariable'];
      final required = item['required'];
      if (name is! String ||
          envName is! String ||
          required is! bool ||
          !RegExp(r'^[A-Z_][A-Z0-9_]*$').hasMatch(envName)) {
        throw const FormatException('secret requirement is invalid');
      }
      final authStrategy = item['authStrategy'];
      if (!const {'none', 'browser_auth', 'api_key', 'local_endpoint'}
          .contains(authStrategy)) {
        throw const FormatException('secret auth strategy is unsupported');
      }
      if (!authStrategies.contains(authStrategy)) {
        throw const FormatException('secret auth strategy was not declared');
      }
      if (!secretNames.add(name) || !environmentNames.add(envName)) {
        throw const FormatException('secret requirements must be unique');
      }
      secrets.add(V7AdapterSecretRequirement(
          name, envName, authStrategy as String, required));
    }
    return V7AdapterAdmission._(
      workerTypeId: workerTypeId,
      adapterVersion: version,
      protocolVersion: protocolVersion,
      publisher: publisher,
      executable: File(resolved),
      launchArgs: List.unmodifiable(launchArgs),
      permissions: declaredPermissions,
      secretRequirements: List.unmodifiable(secrets),
      healthCheckMode: health['mode'] as String,
      healthCheckTimeoutMs: health['timeoutMs'] as int,
    );
  }

  WorkerProcessSpec createProcessSpec({
    required String workerId,
    required String workingDirectory,
    required int localConcurrencyLimit,
    required Map<String, String> availableSecrets,
  }) {
    final environment = <String, String>{};
    final secretValues = <String>{};
    for (final requirement in secretRequirements) {
      final secret = availableSecrets[requirement.name];
      if (secret == null || secret.isEmpty) {
        if (requirement.required) {
          throw StateError('required local adapter credential is unavailable');
        }
        continue;
      }
      environment[requirement.environmentVariable] = secret;
      secretValues.add(secret);
    }
    return WorkerProcessSpec(
      workerId: workerId,
      executable: executable.path,
      arguments: launchArgs,
      workingDirectory: workingDirectory,
      environment: environment,
      allowedEnvironmentVariables: environment.keys.toSet(),
      secretValues: secretValues,
      maxConcurrentAssignments: localConcurrencyLimit,
    );
  }
}

class V7AdapterSecretRequirement {
  const V7AdapterSecretRequirement(
      this.name, this.environmentVariable, this.authStrategy, this.required);
  final String name;
  final String environmentVariable;
  final String authStrategy;
  final bool required;
}

Map<String, Object?> _object(Object? value, String field) {
  if (value is! Map) throw FormatException('$field must be an object');
  return Map<String, Object?>.from(value);
}

List<Object?> _list(Object? value, String field) {
  if (value is! List) throw FormatException('$field must be a list');
  return value.cast<Object?>();
}

List<String> _strings(Object? value, String field) {
  final values = _list(value, field);
  if (values.any((item) => item is! String)) {
    throw FormatException('$field must contain only strings');
  }
  return values.cast<String>();
}
