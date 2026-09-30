import 'dart:convert';
import 'dart:io';

import 'package:conclave_host/worker_candidate_validator.dart';
import 'package:conclave_host/worker_release_manifest.dart';
import 'package:conclave_host/worker_trust_policy.dart';
import 'package:conclave_host/worker_version_store.dart';
import 'package:conclave_host/workspace_paths.dart';

Future<void> main(List<String> args) async {
  final options = _parseArgs(args);
  final workers = options['worker'] as Set<String>;
  if (workers.isEmpty) {
    throw const FormatException('Specify at least one --worker chatgpt|gemini');
  }
  final artifactRoot = Directory(options['artifactRoot'] as String);
  final dataDirectory = options['dataDirectory'] as Directory;
  final workspacePaths = WorkspacePaths(dataDirectory);
  final store = WorkerVersionStore(
    workersRoot: workspacePaths.workersDirectory,
    trustPolicy: WorkerTrustPolicy(allowUnsignedDevelopmentReleases: true),
    allowedPermissions: WorkerPermission.values.toSet(),
    workerStateSchemaVersion: 1,
    candidateHealthCheck: WorkerCandidateValidator(),
  );
  final platform = store.platform;
  for (final workerTypeId in workers) {
    final releaseDirectory = Directory(
      '${artifactRoot.path}${Platform.pathSeparator}$platform'
      '${Platform.pathSeparator}$workerTypeId',
    );
    final manifestFile = File(
      '${releaseDirectory.path}${Platform.pathSeparator}worker-release.json',
    );
    final archiveFile = File(
      '${releaseDirectory.path}${Platform.pathSeparator}worker-release.tgz',
    );
    final manifestJson = jsonDecode(await manifestFile.readAsString());
    final manifest = WorkerReleaseManifest.parse(manifestJson);
    if (manifest.publisher != 'local-development' ||
        manifest.releaseChannel != 'development' ||
        manifest.signingKeyId != 'unsigned-development' ||
        manifest.signature != 'unsigned-development') {
      throw StateError('Refusing non-development artifact for $workerTypeId');
    }
    try {
      await store.installArchive(
        manifestInput: manifestJson,
        archiveBytes: await archiveFile.readAsBytes(),
        expectedWorkerTypeId: workerTypeId,
        activate: !options.containsKey('noActivate'),
      );
    } on WorkerCandidateValidationFailure catch (failure) {
      stderr.writeln(
        'Could not activate $workerTypeId: ${failure.issueCode}. '
        '${failure.safeDiagnostic}',
      );
      exitCode = 1;
      return;
    }
    stdout.writeln(
      'Installed ${manifest.workerTypeId} ${manifest.workerVersion} '
      '(${manifest.platform}) at ${workspacePaths.workersDirectory.path}',
    );
  }
}

Map<String, Object?> _parseArgs(List<String> args) {
  final workers = <String>{'chatgpt', 'gemini'};
  var workerWasSpecified = false;
  var artifactRoot = '../../dist/workers';
  var dataDirectory = WorkspacePaths.defaultStateDirectory();
  var noActivate = false;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--worker':
        if (++i >= args.length ||
            !{'chatgpt', 'gemini', 'all'}.contains(args[i])) {
          throw const FormatException(
              '--worker must be chatgpt, gemini, or all');
        }
        if (!workerWasSpecified) {
          workers.clear();
          workerWasSpecified = true;
        }
        if (args[i] == 'all') {
          workers.addAll(const {'chatgpt', 'gemini'});
        } else {
          workers.add(args[i]);
        }
      case '--artifact-root':
        if (++i >= args.length) {
          throw const FormatException('--artifact-root requires a directory');
        }
        artifactRoot = args[i];
      case '--data-dir':
        if (++i >= args.length) {
          throw const FormatException('--data-dir requires a directory');
        }
        dataDirectory = Directory(args[i]);
      case '--no-activate':
        noActivate = true;
      case '--help' || '-h':
        stdout.writeln(
          'Usage: dart run bin/install_development_workers.dart '
          '[--worker chatgpt|gemini|all] [--worker ...] '
          '[--artifact-root DIR] [--data-dir DIR] [--no-activate]',
        );
        exit(0);
      default:
        throw FormatException('Unknown option: ${args[i]}');
    }
  }
  final root = Directory(artifactRoot);
  return {
    'worker': workers,
    'artifactRoot': root.isAbsolute
        ? root.path
        : Directory.current.uri.resolve(artifactRoot).toFilePath(),
    'dataDirectory': dataDirectory,
    if (noActivate) 'noActivate': true,
  };
}
