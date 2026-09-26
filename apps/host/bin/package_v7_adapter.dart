import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:cryptography/cryptography.dart';

import 'package:conclave_host/v7_adapter_admission.dart';
import 'package:conclave_host/v7_adapter_package_store.dart';
import 'package:conclave_host/worker_trust_policy.dart';

const _maxCloudArchiveBytes = 20 * 1024 * 1024;

Future<void> main(List<String> args) async {
  try {
    final options = _arguments(args);
    final source = Directory(options['source']!).absolute;
    final output = File(options['output']!).absolute;
    final publisher =
        Platform.environment['CONCLAVE_WORKER_TRUST_PUBLISHER'] ?? 'conclave';
    final signingSeed = Platform.environment['CONCLAVE_RELEASE_SIGNING_SEED'];
    final signingKeyId =
        Platform.environment['CONCLAVE_RELEASE_SIGNING_KEY_ID'];
    if (signingSeed == null ||
        signingSeed.isEmpty ||
        signingKeyId == null ||
        signingKeyId.isEmpty) {
      throw StateError(
          'Set CONCLAVE_RELEASE_SIGNING_SEED and CONCLAVE_RELEASE_SIGNING_KEY_ID in the release environment.');
    }
    if (!await source.exists()) {
      throw ArgumentError('Adapter source directory does not exist.');
    }

    final seed = base64.decode(signingSeed);
    if (seed.length != 32) {
      throw StateError('Ed25519 signing seed must be 32 bytes.');
    }
    final signer = await Ed25519().newKeyPairFromSeed(seed);
    final publicKey = await signer.extractPublicKey();
    final trustPolicy = WorkerTrustPolicy(trustedPublicKeys: {
      publisher: {signingKeyId: base64.encode(publicKey.bytes)},
    });
    final store = V7AdapterPackageStore(
      root: Directory('${Directory.systemTemp.path}/conclave-package-check'),
      trustPolicy: trustPolicy,
      allowedPermissions: WorkerPermission.values.toSet(),
    );
    final staging =
        await Directory.systemTemp.createTemp('conclave-adapter-release-');
    try {
      await _copyPackage(source, staging);
      final sharedRuntime =
          Directory('${source.parent.path}${Platform.pathSeparator}shared');
      if (const {'openai-api', 'gemini-api', 'anthropic-api'}
              .contains(source.path.split(Platform.pathSeparator).last) &&
          await sharedRuntime.exists()) {
        await _copySharedRuntime(sharedRuntime, staging);
      }
      final manifestFile =
          File('${staging.path}${Platform.pathSeparator}manifest.json');
      if (!await manifestFile.exists()) {
        throw StateError('Adapter root manifest.json is required.');
      }
      final raw = jsonDecode(await manifestFile.readAsString());
      if (raw is! Map) {
        throw const FormatException('Adapter manifest must be an object.');
      }
      final manifest = Map<String, Object?>.from(raw);
      if (manifest['publisher'] != publisher) {
        throw StateError(
            'Manifest publisher does not match the configured publisher.');
      }
      final workerTypeId = manifest['workerTypeId'];
      if (workerTypeId is! String || workerTypeId.isEmpty) {
        throw const FormatException('Manifest workerTypeId is required.');
      }
      final digest = await store.digestDirectory(staging);
      manifest['packageDigest'] = digest;
      final channel = options['channel'];
      if (channel != null) manifest['releaseChannel'] = channel;
      manifest['signingKeyId'] = signingKeyId;
      manifest['signature'] = '';
      final unsigned = Map<String, Object?>.from(manifest)..remove('signature');
      final signature = await Ed25519().sign(
        utf8.encode(
            'conclave-v7-adapter-release-v1\n$digest\n${canonicalJson(unsigned)}'),
        keyPair: signer,
      );
      manifest['signature'] = base64.encode(signature.bytes);
      await manifestFile.writeAsString(jsonEncode(manifest), flush: true);

      final platforms = manifest['supportedPlatforms'];
      if (platforms is! List ||
          platforms.isEmpty ||
          platforms.first is! String) {
        throw const FormatException('Manifest supportedPlatforms is required.');
      }
      await V7AdapterAdmission.admit(
        input: manifest,
        packageRoot: staging,
        expectedWorkerTypeId: workerTypeId,
        verifiedPackageDigest: digest,
        platform: platforms.first as String,
        trustPolicy: trustPolicy,
        allowedPermissions: WorkerPermission.values.toSet(),
      );
      final archive = Archive();
      final files = <File>[];
      await for (final entity
          in staging.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        files.add(entity);
      }
      files.sort((left, right) => left.path.compareTo(right.path));
      for (final entity in files) {
        final relative = entity.path
            .substring(staging.path.length + 1)
            .replaceAll(Platform.pathSeparator, '/');
        final stat = await entity.stat();
        final entry = ArchiveFile.bytes(relative, await entity.readAsBytes());
        entry.mode = stat.mode & 0x1ff;
        entry.lastModTime = 0;
        archive.addFile(entry);
      }
      final tar = TarEncoder().encode(archive);
      final compressed = GZipEncoder().encode(tar);
      if (compressed.length > _maxCloudArchiveBytes) {
        throw StateError('Compressed release exceeds Cloud\'s 20 MB limit.');
      }

      await output.parent.create(recursive: true);
      await output.writeAsBytes(compressed, flush: true);
      final manifestOutput = File('${output.path}.manifest.json');
      await manifestOutput.writeAsString(
        const JsonEncoder.withIndent('  ').convert(manifest),
        flush: true,
      );
      stdout.writeln(jsonEncode({
        'workerTypeId': workerTypeId,
        'version': manifest['adapterVersion'],
        'packageDigest': digest,
        'archiveBytes': compressed.length,
        'archivePath': output.path,
        'manifestPath': manifestOutput.path,
      }));
    } finally {
      await staging.delete(recursive: true);
    }
  } on Object catch (error) {
    stderr.writeln('V7 adapter package failed: $error');
    exitCode = 1;
  }
}

Map<String, String> _arguments(List<String> args) {
  if (args.length < 4 || args[0] != '--source' || args[2] != '--output') {
    throw ArgumentError(
        'Usage: dart run bin/package_v7_adapter.dart --source <adapter-dir> --output <release.tgz>');
  }
  if (args[1].trim().isEmpty || args[3].trim().isEmpty) {
    throw ArgumentError('Source and output paths must not be empty.');
  }
  final result = {'source': args[1], 'output': args[3]};
  if (args.length > 4) {
    if (args.length != 6 ||
        args[4] != '--channel' ||
        !const {'development', 'beta', 'stable'}.contains(args[5])) {
      throw ArgumentError(
          'Optional channel must be development, beta, or stable.');
    }
    result['channel'] = args[5];
  }
  return result;
}

Future<void> _copyPackage(Directory source, Directory target) async {
  final sourceRoot = await source.resolveSymbolicLinks();
  await for (final entity
      in Directory(sourceRoot).list(recursive: true, followLinks: false)) {
    if (entity is Link) {
      throw StateError('Adapter source cannot contain symlinks.');
    }
    final relative = entity.path.substring(sourceRoot.length + 1);
    if (relative
        .split(Platform.pathSeparator)
        .any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw StateError('Adapter source contains an unsafe path.');
    }
    final packageRelative =
        relative == 'manifest.template.json' ? 'manifest.json' : relative;
    final destination =
        '${target.path}${Platform.pathSeparator}$packageRelative';
    if (entity is Directory) {
      await Directory(destination).create(recursive: true);
    } else if (entity is File) {
      await File(destination).parent.create(recursive: true);
      await entity.copy(destination);
      final mode = (await entity.stat()).mode & 0x1ff;
      if (!Platform.isWindows) {
        final result = await Process.run('chmod', [
          mode.toRadixString(8),
          destination,
        ]);
        if (result.exitCode != 0) {
          throw StateError('Could not preserve adapter file permissions.');
        }
      }
    }
  }
}

Future<void> _copySharedRuntime(Directory source, Directory target) async {
  final root = await source.resolveSymbolicLinks();
  await for (final entity
      in Directory(root).list(recursive: true, followLinks: false)) {
    if (entity is Link) {
      throw StateError('Shared adapter runtime cannot contain symlinks.');
    }
    final relative = entity.path.substring(root.length + 1);
    if (relative
        .split(Platform.pathSeparator)
        .any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw StateError('Shared adapter runtime contains an unsafe path.');
    }
    if (relative.split(Platform.pathSeparator).first == 'test') continue;
    final destination =
        '${target.path}${Platform.pathSeparator}lib${Platform.pathSeparator}$relative';
    if (entity is Directory) {
      await Directory(destination).create(recursive: true);
    } else if (entity is File) {
      await File(destination).parent.create(recursive: true);
      await entity.copy(destination);
      final mode = (await entity.stat()).mode & 0x1ff;
      if (!Platform.isWindows) {
        final result =
            await Process.run('chmod', [mode.toRadixString(8), destination]);
        if (result.exitCode != 0) {
          throw StateError(
              'Could not preserve shared runtime file permissions.');
        }
      }
    }
  }
}
