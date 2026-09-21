import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

class PluginPackage {
  const PluginPackage({
    required this.id,
    required this.version,
    required this.bytes,
    required this.digest,
  });
  final String id;
  final String version;
  final List<int> bytes;
  final String digest;
}

class PluginManager {
  PluginManager(this.root);
  final Directory root;

  Future<Directory> install(PluginPackage package) async {
    final actual = sha256.convert(package.bytes).toString();
    if (actual != package.digest) throw StateError('plugin digest mismatch');
    final target = Directory('${root.path}/${package.id}/${package.version}');
    await target.create(recursive: true);
    await File('${target.path}/package.bin')
        .writeAsBytes(package.bytes, flush: true);
    await File('${root.path}/${package.id}/active.json').writeAsString(
      jsonEncode({'version': package.version, 'digest': actual}),
      flush: true,
    );
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
    await File('${root.path}/$pluginId/active.json').writeAsString(
      jsonEncode({'version': version}),
      flush: true,
    );
  }
}
