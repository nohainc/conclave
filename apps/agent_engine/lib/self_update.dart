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
      this.minimumProtocolVersion,
      this.operatingSystem,
      this.architecture,
      this.releaseNotes,
      this.packageUrl});
  final String version;
  final String channel;
  final List<int> bytes;
  final String digest;
  final String? publisher;
  final String? signature;
  final String? minimumProtocolVersion;
  final String? operatingSystem;
  final String? architecture;
  final String? releaseNotes;
  final String? packageUrl;
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
    final releaseMetadata = File('${root.path}/release.json');
    if (await releaseMetadata.exists()) {
      try {
        final metadata =
            jsonDecode(await releaseMetadata.readAsString()) as Map;
        final activeVersion = metadata['version'];
        if (activeVersion is String &&
            _compareVersions(release.version, activeVersion) < 0) {
          throw StateError(
              'agent release rollback is not permitted: ${release.version} < $activeVersion');
        }
        if (activeVersion == release.version && metadata['digest'] == actual) {
          return;
        }
        if (activeVersion == release.version && metadata['digest'] != actual) {
          throw StateError('agent release version is already installed');
        }
      } on StateError {
        rethrow;
      } on Object {
        throw StateError('active agent release metadata is invalid');
      }
    }
    _validateVersion(release.version);
    final staged = File(
        '${root.path}/.agent-${release.version}.staged-${DateTime.now().microsecondsSinceEpoch}');
    final active = File('${root.path}/agent.active');
    final backup = File('${root.path}/agent.previous');
    try {
      await staged.writeAsBytes(release.bytes, flush: true);
      if (await active.exists()) {
        if (await backup.exists()) await backup.delete();
        await active.rename(backup.path);
      }
      await staged.rename(active.path);
      if (!await healthCheck(active)) {
        if (await active.exists()) await active.delete();
        if (await backup.exists()) await backup.rename(active.path);
        throw StateError('agent release health check failed; rolled back');
      }
    } catch (_) {
      if (await staged.exists()) await staged.delete();
      rethrow;
    }
    final metadata = File('${root.path}/release.json');
    final metadataTemp =
        File('${metadata.path}.tmp-${DateTime.now().microsecondsSinceEpoch}');
    try {
      await metadataTemp.writeAsString(
          jsonEncode({
            'version': release.version,
            'channel': release.channel,
            'digest': actual,
            if (release.publisher != null) 'publisher': release.publisher,
            if (release.signature != null) 'signature': release.signature,
            if (minimumProtocol != null)
              'minimumProtocolVersion': minimumProtocol,
            if (release.operatingSystem != null)
              'operatingSystem': release.operatingSystem,
            if (release.architecture != null)
              'architecture': release.architecture,
            if (release.releaseNotes != null)
              'releaseNotes': release.releaseNotes,
            if (release.packageUrl != null) 'packageUrl': release.packageUrl,
          }),
          flush: true);
      await metadataTemp.rename(metadata.path);
    } catch (_) {
      if (await metadataTemp.exists()) await metadataTemp.delete();
      rethrow;
    }
  }

  void _validateVersion(String version) {
    if (!RegExp(r'^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$').hasMatch(version)) {
      throw StateError('agent release version is invalid');
    }
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

  int _compareVersions(String left, String right) {
    final leftParts = _versionParts(left);
    final rightParts = _versionParts(right);
    for (var index = 0; index < 3; index++) {
      if (leftParts[index] != rightParts[index]) {
        return leftParts[index].compareTo(rightParts[index]);
      }
    }
    return 0;
  }

  List<int> _versionParts(String version) => version
      .split('.')
      .take(3)
      .map((part) => int.tryParse(part.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
      .followedBy(const [0, 0, 0])
      .take(3)
      .toList();
}
