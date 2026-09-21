import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

class ReleasePackage {
  const ReleasePackage(
      {required this.version,
      required this.channel,
      required this.bytes,
      required this.digest});
  final String version;
  final String channel;
  final List<int> bytes;
  final String digest;
}

class AgentUpdater {
  AgentUpdater(this.root);
  final Directory root;

  Future<void> apply(ReleasePackage release,
      {required Future<bool> Function(File executable) healthCheck}) async {
    final actual = sha256.convert(release.bytes).toString();
    if (actual != release.digest) {
      throw StateError('agent release digest mismatch');
    }
    await root.create(recursive: true);
    final staged = File('${root.path}/agent-${release.version}.staged');
    final active = File('${root.path}/agent.active');
    final backup = File('${root.path}/agent.previous');
    await staged.writeAsBytes(release.bytes, flush: true);
    if (await active.exists()) {
      await active.rename(backup.path);
    }
    await staged.rename(active.path);
    if (!await healthCheck(active)) {
      if (await active.exists()) await active.delete();
      if (await backup.exists()) await backup.rename(active.path);
      throw StateError('agent release health check failed; rolled back');
    }
    await File('${root.path}/release.json').writeAsString(
        jsonEncode({
          'version': release.version,
          'channel': release.channel,
          'digest': actual
        }),
        flush: true);
  }
}
