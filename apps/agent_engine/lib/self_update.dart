import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'trust_policy.dart';

class ReleasePackage {
  const ReleasePackage(
      {required this.version,
      required this.channel,
      required this.bytes,
      required this.digest,
      this.publisher,
      this.signature,
      this.minimumProtocolVersion});
  final String version;
  final String channel;
  final List<int> bytes;
  final String digest;
  final String? publisher;
  final String? signature;
  final String? minimumProtocolVersion;
}

class AgentUpdater {
  AgentUpdater(
    this.root, {
    this.trustPolicy,
    this.currentProtocolVersion = '2.0',
  });
  final Directory root;
  final PluginTrustPolicy? trustPolicy;
  final String currentProtocolVersion;

  Future<void> apply(ReleasePackage release,
      {required Future<bool> Function(File executable) healthCheck}) async {
    final actual = sha256.convert(release.bytes).toString();
    if (actual != release.digest) {
      throw StateError('agent release digest mismatch');
    }
    final policy = trustPolicy;
    if (policy != null) {
      final publisher = release.publisher;
      final signature = release.signature;
      if (publisher == null ||
          signature == null ||
          !policy.verify(
            publisher: publisher,
            digest: actual,
            signature: signature,
          )) {
        throw StateError('agent release signature is not trusted');
      }
    }
    final minimumProtocol = release.minimumProtocolVersion;
    if (minimumProtocol != null &&
        !_satisfiesMinimumVersion(currentProtocolVersion, minimumProtocol)) {
      throw StateError('agent release requires an incompatible protocol');
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
          'digest': actual,
          if (release.publisher != null) 'publisher': release.publisher,
          if (release.signature != null) 'signature': release.signature,
          if (minimumProtocol != null)
            'minimumProtocolVersion': minimumProtocol,
        }),
        flush: true);
  }

  bool _satisfiesMinimumVersion(String current, String minimum) {
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
