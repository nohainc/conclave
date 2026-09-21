import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'plugin_executor.dart';
import 'trust_policy.dart';

class PluginManifest {
  const PluginManifest({
    required this.pluginId,
    required this.version,
    required this.protocolVersion,
    required this.engineVersion,
    required this.executable,
    this.arguments = const [],
    this.publisher,
    this.permissions = const [],
    this.supportedPlatforms = const [],
    this.releaseChannel = 'stable',
  });

  final String pluginId;
  final String version;
  final String protocolVersion;
  final String engineVersion;
  final String executable;
  final List<String> arguments;
  final String? publisher;
  final List<PluginPermission> permissions;
  final List<String> supportedPlatforms;
  final String releaseChannel;

  Map<String, Object?> toJson() => {
        'pluginId': pluginId,
        'version': version,
        'protocolVersion': protocolVersion,
        'engineVersion': engineVersion,
        'executable': executable,
        'arguments': arguments,
        if (publisher != null) 'publisher': publisher,
        'permissions':
            permissions.map((permission) => permission.name).toList(),
        'supportedPlatforms': supportedPlatforms,
        'releaseChannel': releaseChannel,
      };
}

class PluginPackage {
  const PluginPackage({
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
  final List<PluginPermission> permissions;
  final PluginManifest? manifest;
}

class InstalledPlugin {
  const InstalledPlugin({
    required this.pluginId,
    required this.version,
    required this.digest,
    required this.active,
    required this.manifest,
  });

  final String pluginId;
  final String version;
  final String digest;
  final bool active;
  final Map<String, Object?> manifest;
}

class PluginManager {
  PluginManager(this.root,
      {this.trustPolicy,
      this.allowedPermissions = const {},
      String? platformKey,
      this.engineVersion = '0.1.0',
      this.protocolVersion = '2.0'})
      : platformKey = platformKey ?? _currentPlatformKey();
  final Directory root;
  final PluginTrustPolicy? trustPolicy;
  final Set<PluginPermission> allowedPermissions;
  final String platformKey;
  final String engineVersion;
  final String protocolVersion;

  /// Installs the versions requested by Cloud during Agent reconciliation.
  /// The package bytes are fetched by the caller so transport/authentication
  /// stays outside the plugin manager, while digest and signature admission
  /// remains centralized here.
  Future<void> reconcile(
    Iterable<Map<String, Object?>> desired, {
    required Future<List<int>> Function(
      String pluginId,
      String version,
      String packageR2Key,
    ) download,
  }) async {
    for (final item in desired) {
      final pluginId = item['pluginId'];
      final version = item['version'];
      final publisher = item['publisher'];
      final packageR2Key = item['packageR2Key'];
      final digest = item['packageDigest'];
      final signature = item['signature'];
      final permissions = item['permissions'];
      final protocolVersion = item['protocolVersion'];
      final minAgentVersion = item['minAgentVersion'];
      final supportedPlatforms = item['supportedPlatforms'];
      if (pluginId is! String ||
          version is! String ||
          publisher is! String ||
          packageR2Key is! String ||
          digest is! String ||
          signature is! String ||
          permissions is! List) {
        throw StateError('Cloud returned an invalid desired plugin');
      }
      if (await activeVersion(pluginId) == version) continue;
      final bytes = await download(pluginId, version, packageR2Key);
      await install(PluginPackage(
        id: pluginId,
        version: version,
        bytes: bytes,
        digest: digest,
        publisher: publisher,
        signature: signature,
        permissions: permissions
            .whereType<String>()
            .map((value) => PluginPermission.values.firstWhere(
                  (permission) => permission.name == value,
                  orElse: () => throw StateError(
                    'desired plugin contains an unknown permission',
                  ),
                ))
            .toList(),
        manifest: PluginManifest(
          pluginId: pluginId,
          version: version,
          protocolVersion: protocolVersion is String
              ? protocolVersion
              : this.protocolVersion,
          engineVersion:
              minAgentVersion is String ? '>=$minAgentVersion' : '>=0.1.0',
          executable: 'package.bin',
          publisher: publisher,
          permissions: permissions
              .whereType<String>()
              .map((value) => PluginPermission.values.firstWhere(
                    (permission) => permission.name == value,
                    orElse: () => throw StateError(
                      'desired plugin contains an unknown permission',
                    ),
                  ))
              .toList(),
          supportedPlatforms: supportedPlatforms is List
              ? supportedPlatforms.whereType<String>().toList()
              : const [],
        ),
      ));
    }
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

  Future<Directory> install(PluginPackage package) async {
    _validatePathComponent(package.id, 'plugin id');
    _validatePathComponent(package.version, 'plugin version');
    final actual = sha256.convert(package.bytes).toString();
    if (actual != package.digest) throw StateError('plugin digest mismatch');
    if (trustPolicy != null) {
      final publisher = package.publisher;
      final signature = package.signature;
      if (publisher == null ||
          signature == null ||
          !trustPolicy!.verify(
              publisher: publisher, digest: actual, signature: signature)) {
        throw StateError('plugin signature is not trusted');
      }
      trustPolicy!.requirePermissions(package.permissions, allowedPermissions);
    }
    final manifest = package.manifest ??
        PluginManifest(
          pluginId: package.id,
          version: package.version,
          protocolVersion: '2.0',
          engineVersion: '>=0.1.0',
          executable: 'package.bin',
          publisher: package.publisher,
          permissions: package.permissions,
        );
    if (manifest.pluginId != package.id ||
        manifest.version != package.version) {
      throw StateError('plugin manifest identity does not match package');
    }
    if (manifest.publisher != null &&
        package.publisher != null &&
        manifest.publisher != package.publisher) {
      throw StateError('plugin manifest publisher does not match package');
    }
    _requirePermissions(manifest.permissions);
    if (manifest.protocolVersion != protocolVersion ||
        !_satisfiesMinimumVersion(engineVersion, manifest.engineVersion)) {
      throw StateError('plugin is incompatible with this Agent Engine');
    }
    if (manifest.supportedPlatforms.isNotEmpty &&
        !manifest.supportedPlatforms.contains(platformKey)) {
      throw StateError('plugin is not compatible with platform $platformKey');
    }
    final versionRoot = Directory('${root.path}/${package.id}');
    final target = Directory('${versionRoot.path}/${package.version}');
    if (await target.exists()) {
      final installedDigest = await _installedDigest(target);
      if (installedDigest == actual) {
        await _activate(package.id, package.version, actual);
        return target;
      }
      throw StateError('plugin version is already installed');
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
          'digest': actual,
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
    await _activate(package.id, package.version, actual);
    return target;
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
    return actual == digest ? actual : null;
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

  Future<String?> activeVersion(String pluginId) async {
    final file = File('${root.path}/$pluginId/active.json');
    if (!await file.exists()) return null;
    final json = jsonDecode(await file.readAsString()) as Map;
    return json['version'] as String?;
  }

  Future<void> rollback(String pluginId, String version) async {
    if (!await Directory('${root.path}/$pluginId/$version').exists()) {
      throw StateError('plugin version is not installed');
    }
    final manifestFile = File(
      '${root.path}/$pluginId/$version/manifest.json',
    );
    if (!await manifestFile.exists()) {
      throw StateError('plugin manifest is missing');
    }
    final manifest = jsonDecode(await manifestFile.readAsString()) as Map;
    await _activate(pluginId, version, manifest['digest'] as String?);
  }

  Future<PluginProcessSpec?> activeProcessSpec(String pluginId) async {
    final version = await activeVersion(pluginId);
    if (version == null) return null;
    final manifest = await _verifiedManifest(pluginId, version);
    final executable = manifest['executable'];
    if (executable is! String || executable.isEmpty) {
      throw StateError('plugin executable is missing');
    }
    // PluginPackage currently stores one immutable executable payload. Do not
    // allow a mutable manifest to redirect execution to another local binary.
    if (executable != 'package.bin') {
      throw StateError(
          'plugin executable must be the verified package payload');
    }
    final packageDirectory = Directory('${root.path}/$pluginId/$version');
    final packageRoot = await packageDirectory.resolveSymbolicLinks();
    final executableFile = File('${packageDirectory.path}/package.bin');
    final executablePath = await executableFile.resolveSymbolicLinks();
    final containedPrefix = packageRoot.endsWith(Platform.pathSeparator)
        ? packageRoot
        : '$packageRoot${Platform.pathSeparator}';
    if (!executablePath.startsWith(containedPrefix)) {
      throw StateError('plugin executable escapes its package directory');
    }
    final arguments = manifest['arguments'];
    return PluginProcessSpec(
      pluginId: pluginId,
      executable: executablePath,
      arguments:
          arguments is List ? arguments.whereType<String>().toList() : const [],
      workingDirectory: '${root.path}/$pluginId/$version',
    );
  }

  /// Re-check the immutable package payload before every process launch.
  /// Installation-time verification alone is insufficient because a local
  /// attacker or a broken updater could modify the package afterward.
  Future<Map<String, Object?>> _verifiedManifest(
    String pluginId,
    String version,
  ) async {
    final directory = Directory('${root.path}/$pluginId/$version');
    final manifestFile = File('${directory.path}/manifest.json');
    final packageFile = File('${directory.path}/package.bin');
    if (!await manifestFile.exists() || !await packageFile.exists()) {
      throw StateError('plugin package is incomplete');
    }
    final manifest = Map<String, Object?>.from(
      jsonDecode(await manifestFile.readAsString()) as Map,
    );
    if (manifest['pluginId'] != pluginId || manifest['version'] != version) {
      throw StateError('plugin manifest identity does not match installation');
    }
    if (manifest['protocolVersion'] != protocolVersion ||
        manifest['engineVersion'] is! String ||
        !_satisfiesMinimumVersion(
            engineVersion, manifest['engineVersion'] as String)) {
      throw StateError('plugin is incompatible with this Agent Engine');
    }
    final supportedPlatforms = manifest['supportedPlatforms'];
    if (supportedPlatforms is List &&
        supportedPlatforms.isNotEmpty &&
        !supportedPlatforms.contains(platformKey)) {
      throw StateError('plugin is not compatible with platform $platformKey');
    }
    final expectedDigest = manifest['digest'];
    if (expectedDigest is! String || expectedDigest.isEmpty) {
      throw StateError('plugin package digest is missing');
    }
    final actualDigest =
        sha256.convert(await packageFile.readAsBytes()).toString();
    if (actualDigest != expectedDigest) {
      throw StateError('plugin package was modified after installation');
    }
    final policy = trustPolicy;
    _requirePermissions(_permissionsFromManifest(manifest['permissions']));
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
        throw StateError('plugin signing trust has been revoked');
      }
      policy.requirePermissions(
        _permissionsFromManifest(manifest['permissions']),
        allowedPermissions,
      );
    }
    return manifest;
  }

  void _requirePermissions(Iterable<PluginPermission> permissions) {
    const policy = PluginTrustPolicy();
    policy.requirePermissions(permissions, allowedPermissions);
  }

  List<PluginPermission> _permissionsFromManifest(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<String>()
        .map((value) => PluginPermission.values.firstWhere(
              (permission) => permission.name == value,
              orElse: () => throw StateError(
                'plugin manifest contains an unknown permission',
              ),
            ))
        .toList();
  }

  Future<List<InstalledPlugin>> inventory() async {
    if (!await root.exists()) return [];
    final result = <InstalledPlugin>[];
    await for (final pluginEntity in root.list(followLinks: false)) {
      if (pluginEntity is! Directory) continue;
      final pluginId = pluginEntity.path.split(Platform.pathSeparator).last;
      final active = await activeVersion(pluginId);
      await for (final versionEntity in pluginEntity.list(followLinks: false)) {
        if (versionEntity is! Directory) continue;
        final version = versionEntity.path.split(Platform.pathSeparator).last;
        final manifestFile = File('${versionEntity.path}/manifest.json');
        if (!await manifestFile.exists()) continue;
        final manifest = Map<String, Object?>.from(
          jsonDecode(await manifestFile.readAsString()) as Map,
        );
        final digest = manifest['digest'];
        if (digest is! String) continue;
        result.add(InstalledPlugin(
          pluginId: pluginId,
          version: version,
          digest: digest,
          active: active == version,
          manifest: manifest,
        ));
      }
    }
    return result;
  }

  Future<void> remove(String pluginId, String version) async {
    if (await activeVersion(pluginId) == version) {
      throw StateError('cannot remove the active plugin version');
    }
    final target = Directory('${root.path}/$pluginId/$version');
    if (await target.exists()) await target.delete(recursive: true);
  }

  PluginAssignmentHandler assignmentHandler(PluginProcessExecutor executor) =>
      PluginAssignmentHandler(
        executor: executor,
        resolve: activeProcessSpec,
      );

  Future<void> _activate(
      String pluginId, String version, String? digest) async {
    final activeFile = File('${root.path}/$pluginId/active.json');
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
