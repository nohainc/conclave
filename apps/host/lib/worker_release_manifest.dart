import 'dart:io';
import 'dart:ffi';

const workerReleaseManifestVersion = 2;
const supportedWorkerPlatforms = {
  'macos-arm64',
  'macos-x64',
  'linux-arm64',
  'linux-x64',
  'windows-arm64',
  'windows-x64',
};

/// Provider-neutral metadata for one immutable native Worker release.
class WorkerReleaseManifest {
  WorkerReleaseManifest._({
    required this.workerTypeId,
    required this.workerVersion,
    required this.publisher,
    required this.platform,
    required this.protocolMin,
    required this.protocolMax,
    required this.stateReadMin,
    required this.stateReadMax,
    required this.stateWrite,
    required this.capabilities,
    required this.permissions,
    required this.executable,
    required this.releaseChannel,
    required this.packageDigest,
    required this.archiveSha256,
    required this.signingKeyId,
    required this.signature,
  });

  final String workerTypeId;
  final String workerVersion;
  final String publisher;
  final String platform;
  final String protocolMin;
  final String protocolMax;
  final int stateReadMin;
  final int stateReadMax;
  final int stateWrite;
  final List<String> capabilities;
  final List<String> permissions;
  final String executable;
  final String releaseChannel;
  final String packageDigest;
  final String archiveSha256;
  final String signingKeyId;
  final String signature;

  bool supportsProtocol(String version) =>
      _compareProtocolVersions(version, protocolMin) >= 0 &&
      _compareProtocolVersions(version, protocolMax) <= 0;

  Map<String, Object?> toJson({bool includeSignature = true}) => {
        'manifestVersion': workerReleaseManifestVersion,
        'workerTypeId': workerTypeId,
        'workerVersion': workerVersion,
        'publisher': publisher,
        'platform': platform,
        'protocol': {'min': protocolMin, 'max': protocolMax},
        'stateSchema': {
          'readMin': stateReadMin,
          'readMax': stateReadMax,
          'write': stateWrite,
        },
        'capabilities': capabilities,
        'permissions': permissions,
        'executable': executable,
        'releaseChannel': releaseChannel,
        'packageDigest': packageDigest,
        'archiveSha256': archiveSha256,
        'signingKeyId': signingKeyId,
        if (includeSignature) 'signature': signature,
      };

  factory WorkerReleaseManifest.parse(Object? input) {
    final value = _object(input, 'Worker release manifest');
    const fields = {
      'manifestVersion',
      'workerTypeId',
      'workerVersion',
      'publisher',
      'platform',
      'protocol',
      'stateSchema',
      'capabilities',
      'permissions',
      'executable',
      'releaseChannel',
      'packageDigest',
      'archiveSha256',
      'signingKeyId',
      'signature',
    };
    if (value.keys.any((key) => !fields.contains(key)) ||
        fields.any((key) => !value.containsKey(key))) {
      throw const FormatException('Worker release manifest fields are invalid');
    }
    if (value['manifestVersion'] != workerReleaseManifestVersion) {
      throw const FormatException(
          'unsupported Worker release manifest version');
    }
    String text(Object? raw, String field, {int maxLength = 256}) {
      if (raw is! String || raw.trim().isEmpty || raw.length > maxLength) {
        throw FormatException('$field must be bounded non-empty text');
      }
      return raw.trim();
    }

    final workerTypeId =
        text(value['workerTypeId'], 'workerTypeId', maxLength: 64);
    final workerVersion =
        text(value['workerVersion'], 'workerVersion', maxLength: 128);
    final publisher = text(value['publisher'], 'publisher');
    final platform = text(value['platform'], 'platform', maxLength: 32);
    if (!RegExp(r'^[a-z0-9][a-z0-9._-]*$').hasMatch(workerTypeId) ||
        !_isSemver(workerVersion) ||
        !supportedWorkerPlatforms.contains(platform)) {
      throw const FormatException('Worker release identity is invalid');
    }

    final protocol = _object(value['protocol'], 'protocol');
    _requireExactKeys(protocol, const {'min', 'max'}, 'protocol');
    final protocolMin = text(protocol['min'], 'protocol.min', maxLength: 16);
    final protocolMax = text(protocol['max'], 'protocol.max', maxLength: 16);
    if (!_isProtocolVersion(protocolMin) ||
        !_isProtocolVersion(protocolMax) ||
        _compareProtocolVersions(protocolMin, protocolMax) > 0) {
      throw const FormatException('Worker protocol range is invalid');
    }

    final stateSchema = _object(value['stateSchema'], 'stateSchema');
    _requireExactKeys(
      stateSchema,
      const {'readMin', 'readMax', 'write'},
      'stateSchema',
    );
    final readMin = _positiveInt(stateSchema['readMin'], 'stateSchema.readMin');
    final readMax = _positiveInt(stateSchema['readMax'], 'stateSchema.readMax');
    final stateWrite = _positiveInt(stateSchema['write'], 'stateSchema.write');
    if (readMin > readMax || stateWrite < readMin || stateWrite > readMax) {
      throw const FormatException('Worker state schema range is invalid');
    }

    List<String> identifiers(Object? raw, String field, int maxCount) {
      final list = _list(raw, field);
      if (list.length > maxCount || list.any((item) => item is! String)) {
        throw FormatException('$field must be a bounded string list');
      }
      final strings = list.cast<String>();
      if (strings.any((item) =>
              item.length > 128 ||
              !RegExp(r'^[a-z][a-z0-9:_-]*$').hasMatch(item)) ||
          strings.toSet().length != strings.length) {
        throw FormatException(
            '$field contains invalid or duplicate identifiers');
      }
      return List.unmodifiable(strings);
    }

    final capabilities =
        identifiers(value['capabilities'], 'capabilities', 128);
    final permissions = identifiers(value['permissions'], 'permissions', 64);
    final executable = text(value['executable'], 'executable', maxLength: 512);
    if (!_isPackageRelativePath(executable)) {
      throw const FormatException(
          'Worker executable must stay inside its package');
    }
    final releaseChannel =
        text(value['releaseChannel'], 'releaseChannel', maxLength: 16);
    if (!const {'stable', 'beta', 'development'}.contains(releaseChannel)) {
      throw const FormatException('Worker release channel is invalid');
    }
    final packageDigest =
        text(value['packageDigest'], 'packageDigest', maxLength: 64);
    final archiveSha256 =
        text(value['archiveSha256'], 'archiveSha256', maxLength: 64);
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(packageDigest) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(archiveSha256)) {
      throw const FormatException(
          'Worker release digests must be lowercase SHA-256');
    }
    final signingKeyId =
        text(value['signingKeyId'], 'signingKeyId', maxLength: 64);
    if (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(signingKeyId)) {
      throw const FormatException('Worker signing key ID is invalid');
    }
    final signature = text(value['signature'], 'signature', maxLength: 256);

    return WorkerReleaseManifest._(
      workerTypeId: workerTypeId,
      workerVersion: workerVersion,
      publisher: publisher,
      platform: platform,
      protocolMin: protocolMin,
      protocolMax: protocolMax,
      stateReadMin: readMin,
      stateReadMax: readMax,
      stateWrite: stateWrite,
      capabilities: capabilities,
      permissions: permissions,
      executable: executable,
      releaseChannel: releaseChannel,
      packageDigest: packageDigest,
      archiveSha256: archiveSha256,
      signingKeyId: signingKeyId,
      signature: signature,
    );
  }
}

String currentWorkerPlatform() {
  final os = switch (Platform.operatingSystem) {
    'macos' => 'macos',
    'linux' => 'linux',
    'windows' => 'windows',
    _ => throw UnsupportedError('unsupported Worker platform'),
  };
  final architecture = switch (Abi.current()) {
    Abi.macosArm64 || Abi.linuxArm64 || Abi.windowsArm64 => 'arm64',
    Abi.macosX64 || Abi.linuxX64 || Abi.windowsX64 => 'x64',
    _ => throw UnsupportedError('unsupported Worker architecture'),
  };
  return '$os-$architecture';
}

int _positiveInt(Object? value, String field) {
  if (value is! int || value < 1) {
    throw FormatException('$field must be a positive integer');
  }
  return value;
}

bool _isSemver(String value) => RegExp(
      r'^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$',
    ).hasMatch(value);

bool _isProtocolVersion(String value) =>
    RegExp(r'^(0|[1-9]\d*)\.(0|[1-9]\d*)$').hasMatch(value);

int _compareProtocolVersions(String left, String right) {
  final leftParts = left.split('.').map(int.parse).toList();
  final rightParts = right.split('.').map(int.parse).toList();
  final major = leftParts.first.compareTo(rightParts.first);
  return major != 0 ? major : leftParts.last.compareTo(rightParts.last);
}

bool _isPackageRelativePath(String value) =>
    value.isNotEmpty &&
    !value.contains('\\') &&
    !value.startsWith('/') &&
    !RegExp(r'^[A-Za-z]:').hasMatch(value) &&
    !value.contains('\u0000') &&
    value
        .split('/')
        .every((part) => part.isNotEmpty && part != '.' && part != '..');

Map<String, Object?> _object(Object? value, String field) {
  if (value is! Map) throw FormatException('$field must be an object');
  return Map<String, Object?>.from(value);
}

List<Object?> _list(Object? value, String field) {
  if (value is! List) throw FormatException('$field must be a list');
  return value.cast<Object?>();
}

void _requireExactKeys(
    Map<String, Object?> value, Set<String> keys, String field) {
  if (value.keys.toSet().difference(keys).isNotEmpty ||
      keys.difference(value.keys.toSet()).isNotEmpty) {
    throw FormatException('$field fields are invalid');
  }
}
