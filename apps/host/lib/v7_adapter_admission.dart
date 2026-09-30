import 'dart:io';

import 'first_party_worker_registry.dart';
import 'worker_executor.dart';
import 'worker_trust_policy.dart';
import 'v7_adapter_protocol.dart';

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
    required this.environmentPassthrough,
    required this.providerCliPassthrough,
    required this.sensitiveEnvironmentPassthrough,
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

  /// Parent environment names the Workspace may copy into this package.
  final Set<String> environmentPassthrough;

  /// Package-owned provider child environment policy, validated as signed
  /// metadata but interpreted only by the package itself.
  final Set<String> providerCliPassthrough;
  final Set<String> sensitiveEnvironmentPassthrough;
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
    bool allowUnsignedBundledAdapter = false,
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
      'environmentPolicy',
      // Accepted only for already-published packages during migration.
      'environmentRequirements',
      'executable',
      'launchArgs',
      'secretRequirements',
      'healthCheck',
      'packageDigest',
      'signingKeyId',
      'signature',
      'releaseChannel',
    };
    final requiredFields = fields.difference({
      'environmentPolicy',
      'environmentRequirements',
    });
    if (value.keys.any((key) => !fields.contains(key)) ||
        requiredFields.any((key) => !value.containsKey(key))) {
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
    final signature = value['signature'];
    final signingKeyId = value['signingKeyId'];
    if (signature is! String || signingKeyId is! String) {
      throw const FormatException('adapter signature fields are invalid');
    }
    if (workerTypeId != expectedWorkerTypeId ||
        !RegExp(r'^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$')
            .hasMatch(version) ||
        !supportedV7AdapterProtocolVersions.contains(protocolVersion) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) ||
        digest != verifiedPackageDigest.toLowerCase()) {
      throw const FormatException(
          'adapter identity or package digest mismatch');
    }
    final releaseChannel = value['releaseChannel'];
    final unsignedBundledAdapter = allowUnsignedBundledAdapter &&
        FirstPartyWorkerPackage.forPackageId(workerTypeId) != null &&
        releaseChannel == 'stable' &&
        signingKeyId.isEmpty &&
        signature.isEmpty;
    if (!unsignedBundledAdapter &&
        !await trustPolicy.verifyAdapterManifest(
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
    final legacyEnvironmentRequirements = value['environmentRequirements'] ==
            null
        ? const <String>[]
        : _strings(value['environmentRequirements'], 'environmentRequirements');
    final rawEnvironmentPolicy = value['environmentPolicy'];
    final environmentPolicy = rawEnvironmentPolicy == null
        ? <String, Object?>{}
        : _object(rawEnvironmentPolicy, 'environmentPolicy');
    const environmentPolicyFields = {
      'environmentPassthrough',
      'providerCliPassthrough',
      'sensitivePassthrough',
    };
    if (environmentPolicy.keys
        .any((key) => !environmentPolicyFields.contains(key))) {
      throw const FormatException(
          'adapter environment policy fields are invalid');
    }
    List<String> policyNames(String key) {
      final raw = environmentPolicy[key];
      return raw == null
          ? const <String>[]
          : _strings(raw, 'environmentPolicy.$key');
    }

    final rawEnvironmentPassthrough = policyNames('environmentPassthrough');
    final rawProviderCliPassthrough = policyNames('providerCliPassthrough');
    final rawSensitivePassthrough = policyNames('sensitivePassthrough');
    final environmentPassthrough = rawEnvironmentPassthrough.toSet();
    final providerCliPassthrough = rawProviderCliPassthrough.toSet();
    final sensitivePassthrough = rawSensitivePassthrough.toSet();
    if (legacyEnvironmentRequirements.length > 64 ||
        rawEnvironmentPassthrough.length > 64 ||
        rawProviderCliPassthrough.length > 64 ||
        rawSensitivePassthrough.length > 64 ||
        environmentPassthrough.length > 64 ||
        providerCliPassthrough.length > 64 ||
        sensitivePassthrough.length > 64 ||
        {
          ...legacyEnvironmentRequirements,
          ...environmentPassthrough,
          ...providerCliPassthrough,
          ...sensitivePassthrough,
        }.any((name) => !RegExp(r'^[A-Z_][A-Z0-9_]*$').hasMatch(name)) ||
        legacyEnvironmentRequirements.toSet().length !=
            legacyEnvironmentRequirements.length ||
        environmentPassthrough.length != rawEnvironmentPassthrough.length ||
        providerCliPassthrough.length != rawProviderCliPassthrough.length ||
        sensitivePassthrough.length != rawSensitivePassthrough.length ||
        !environmentPassthrough.containsAll(sensitivePassthrough) ||
        !environmentPassthrough.containsAll(providerCliPassthrough)) {
      throw const FormatException('adapter environment policy is invalid');
    }
    final effectiveEnvironmentPassthrough = {
      ...legacyEnvironmentRequirements,
      ...environmentPassthrough,
    };
    final health = _object(value['healthCheck'], 'healthCheck');
    if (health['mode'] != 'protocol' ||
        health['timeoutMs'] is! int ||
        (health['timeoutMs'] as int) < 100 ||
        (health['timeoutMs'] as int) > 30000) {
      throw const FormatException('adapter health check is invalid');
    }
    if (!const {'stable', 'beta', 'development'}.contains(releaseChannel)) {
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
      environmentPassthrough: effectiveEnvironmentPassthrough,
      providerCliPassthrough: providerCliPassthrough,
      sensitiveEnvironmentPassthrough: sensitivePassthrough,
      healthCheckMode: health['mode'] as String,
      healthCheckTimeoutMs: health['timeoutMs'] as int,
    );
  }

  WorkerProcessSpec createProcessSpec({
    required String workerId,
    required String workingDirectory,
    required int localConcurrencyLimit,
    required Map<String, String> availableSecrets,
    String? workerStateDirectory,
  }) {
    final environment = createPackageEnvironment();
    final secretValues = <String>{
      for (final name in sensitiveEnvironmentPassthrough)
        if (environment[name] case final value?) value,
    };
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
      protocolVersion: protocolVersion,
      arguments: launchArgs,
      workingDirectory: workingDirectory,
      environment: {
        ...environment,
        if (workerStateDirectory != null)
          'CONCLAVE_WORKER_STATE_DIR': workerStateDirectory,
      },
      allowedEnvironmentVariables: {
        ...environmentPassthrough,
        ...environment.keys,
      },
      secretValues: secretValues,
      maxConcurrentAssignments: localConcurrencyLimit,
      includeParentEnvironment: false,
    );
  }

  /// Builds the package's bounded environment from the signed passthrough
  /// policy. Host variables not named by the package never enter this map.
  Map<String, String> createPackageEnvironment() {
    final environment = <String, String>{};
    for (final name in environmentPassthrough) {
      final value = Platform.environment[name];
      if (value != null && value.isNotEmpty) environment[name] = value;
    }
    return environment;
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
