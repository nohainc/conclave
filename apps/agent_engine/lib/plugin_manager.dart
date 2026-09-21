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

class PluginManager {
  PluginManager(this.root,
      {this.trustPolicy, this.allowedPermissions = const {}});
  final Directory root;
  final PluginTrustPolicy? trustPolicy;
  final Set<PluginPermission> allowedPermissions;

  Future<Directory> install(PluginPackage package) async {
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
    final target = Directory('${root.path}/${package.id}/${package.version}');
    await target.create(recursive: true);
    await File('${target.path}/package.bin')
        .writeAsBytes(package.bytes, flush: true);
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
    await File('${target.path}/manifest.json').writeAsString(
      jsonEncode({...manifest.toJson(), 'digest': actual}),
      flush: true,
    );
    await _activate(package.id, package.version, actual);
    return target;
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
    final manifestFile = File(
      '${root.path}/$pluginId/$version/manifest.json',
    );
    if (!await manifestFile.exists()) {
      throw StateError('plugin manifest is missing');
    }
    final manifest = jsonDecode(await manifestFile.readAsString()) as Map;
    final executable = manifest['executable'];
    if (executable is! String || executable.isEmpty) {
      throw StateError('plugin executable is missing');
    }
    final arguments = manifest['arguments'];
    return PluginProcessSpec(
      pluginId: pluginId,
      executable: executable,
      arguments:
          arguments is List ? arguments.whereType<String>().toList() : const [],
      workingDirectory: '${root.path}/$pluginId/$version',
    );
  }

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
}
