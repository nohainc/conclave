import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// Opt-in host acceptance for the Full Local Access mode.
///
/// This test deliberately does not run in normal CI: it reaches the public
/// network, clones a repository, and executes the installed host tools. Run it
/// on the designated Workspace machine with
/// `CONCLAVE_TEST_FULL_LOCAL_ACCESS=1`.
void main() {
  final enabled =
      Platform.environment['CONCLAVE_TEST_FULL_LOCAL_ACCESS'] == '1';
  test(
    'Host network, Git, filesystem and process access',
    () async {
      final evidence = <String, Object?>{
        'schemaVersion': 1,
        'startedAt': DateTime.now().toUtc().toIso8601String(),
        'host': Platform.operatingSystem,
        'checks': <String, Object?>{},
      };
      try {
        await _runHostAcceptance(evidence);
        (evidence['checks'] as Map<String, Object?>)['overall'] = 'passed';
      } catch (error) {
        (evidence['checks'] as Map<String, Object?>)['overall'] = 'failed';
        (evidence['error'] = error.toString());
        rethrow;
      } finally {
        evidence['finishedAt'] = DateTime.now().toUtc().toIso8601String();
        await _writeEvidenceIfConfigured(evidence);
      }
    },
    skip: enabled
        ? false
        : 'Set CONCLAVE_TEST_FULL_LOCAL_ACCESS=1 on the designated Workspace machine.',
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

Future<void> _runHostAcceptance(Map<String, Object?> evidence) async {
  final checks = evidence['checks']! as Map<String, Object?>;
  final repositoryUrl = Platform.environment['CONCLAVE_TEST_HOST_REPOSITORY'] ??
      'https://github.com/nohainc/conclave.git';
  final generalUrl =
      Platform.environment['CONCLAVE_TEST_HOST_URL'] ?? 'https://github.com';

  final git = await _commandPath('git');
  checks['gitPath'] = git;
  checks['gitVersion'] = (await _run(git, ['--version'])).stdout.trim();

  final providerVersions = <String, String>{};
  final configuredProviders =
      (Platform.environment['CONCLAVE_TEST_HOST_PROVIDER_COMMANDS'] ??
              'agy,codex')
          .split(',')
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty);
  for (final provider in configuredProviders) {
    final path = await _commandPathOrNull(provider);
    if (path == null) continue;
    final result = await _run(path, ['--version']);
    providerVersions[provider] = (result.stdout.toString().trim().isEmpty
            ? result.stderr
            : result.stdout)
        .toString()
        .trim();
  }
  if (providerVersions.isEmpty) {
    throw StateError(
      'No configured provider CLI was found. Set '
      'CONCLAVE_TEST_HOST_PROVIDER_COMMANDS or install agy/codex.',
    );
  }
  checks['providerVersions'] = providerVersions;

  final addresses = await InternetAddress.lookup(Uri.parse(generalUrl).host)
      .timeout(const Duration(seconds: 15));
  if (addresses.isEmpty) {
    throw StateError('DNS lookup returned no addresses for $generalUrl.');
  }
  checks['dns'] = {
    'host': Uri.parse(generalUrl).host,
    'resolved': true,
  };

  final client = HttpClient();
  try {
    final request = await client.headUrl(Uri.parse(generalUrl));
    request.followRedirects = true;
    final response = await request.close().timeout(const Duration(seconds: 20));
    await response.drain<void>();
    if (response.statusCode >= 500) {
      throw StateError(
        'HTTPS request to $generalUrl returned ${response.statusCode}.',
      );
    }
    checks['https'] = {
      'url': generalUrl,
      'statusCode': response.statusCode,
    };
  } finally {
    client.close(force: true);
  }

  final lsRemote = await _run(git, ['ls-remote', '--heads', repositoryUrl]);
  if (lsRemote.stdout.toString().trim().isEmpty) {
    throw StateError('git ls-remote returned no refs for $repositoryUrl.');
  }
  checks['gitLsRemote'] = {'repository': repositoryUrl, 'succeeded': true};

  final root = await Directory.systemTemp.createTemp('conclave-host-host-');
  try {
    final checkout = Directory('${root.path}/checkout');
    final clone = await _run(
        git,
        [
          'clone',
          '--depth=1',
          repositoryUrl,
          checkout.path,
        ],
        allowFailure: true);
    if (clone.exitCode != 0) {
      throw StateError('git clone failed: ${clone.stderr}');
    }

    final sourceFile = _findReadableRepositoryFile(checkout);
    final sourceContents = await sourceFile.readAsString();
    if (sourceContents.isEmpty) {
      throw StateError('Cloned repository file was unexpectedly empty.');
    }
    final marker = File('${checkout.path}/.conclave-host-marker');
    await marker.writeAsString('full-local-access\n');
    await _run(git, ['add', marker.path], workingDirectory: checkout.path);
    final commit = await _run(
      git,
      [
        '-c',
        'user.name=Conclave Host Acceptance',
        '-c',
        'user.email=host-acceptance@conclave.invalid',
        'commit',
        '-qm',
        'Host access verification',
      ],
      workingDirectory: checkout.path,
    );
    if (commit.exitCode != 0) {
      throw StateError('git commit failed: ${commit.stderr}');
    }

    final childScript = File('${root.path}/child.dart');
    await childScript.writeAsString(r'''
import 'dart:io';

Future<void> main(List<String> args) async {
  final marker = File(args.single);
  if (!marker.existsSync()) {
    if (args.length != 1) exit(2);
    await marker.writeAsString('child-created\n');
    return;
  }
  stdout.write(await marker.readAsString());
}
''');
    final firstChild = await _run(
      Platform.resolvedExecutable,
      [childScript.path, '${checkout.path}/.restart-marker'],
      workingDirectory: checkout.path,
    );
    if (firstChild.exitCode != 0) {
      throw StateError('First child process failed: ${firstChild.stderr}');
    }
    final restartedChild = await _run(
      Platform.resolvedExecutable,
      [childScript.path, '${checkout.path}/.restart-marker'],
      workingDirectory: checkout.path,
    );
    if (restartedChild.stdout.toString() != 'child-created\n') {
      throw StateError(
        'A restarted child process could not see the same working directory.',
      );
    }

    checks['gitClone'] = {'succeeded': true};
    checks['repositoryRead'] = {'path': sourceFile.path, 'succeeded': true};
    checks['repositoryWrite'] = {'succeeded': true};
    checks['gitCommit'] = {'succeeded': true};
    checks['processRestart'] = {'sameWorkingDirectory': true};
    checks['workingDirectory'] = checkout.path;
  } finally {
    await root.delete(recursive: true);
  }
}

Future<String> _commandPath(String command) async {
  final path = await _commandPathOrNull(command);
  if (path == null) throw StateError('Required command not found: $command');
  return path;
}

Future<String?> _commandPathOrNull(String command) async {
  final result = await Process.run('/bin/sh', ['-lc', 'command -v "$command"']);
  if (result.exitCode != 0) return null;
  final path = result.stdout.toString().trim();
  return path.isEmpty ? null : path;
}

Future<ProcessResult> _run(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  bool allowFailure = false,
}) async {
  final result = await Process.run(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    runInShell: false,
  );
  if (!allowFailure && result.exitCode != 0) {
    throw StateError(
      '$executable ${arguments.join(' ')} failed: ${result.stderr}',
    );
  }
  return result;
}

File _findReadableRepositoryFile(Directory checkout) {
  final preferred = <String>['README.md', 'README', 'AGENTS.md'];
  for (final name in preferred) {
    final file = File('${checkout.path}/$name');
    if (file.existsSync()) return file;
  }
  final files = checkout
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .where((file) => !file.path
          .contains('${Platform.pathSeparator}.git${Platform.pathSeparator}'));
  return files.first;
}

Future<void> _writeEvidenceIfConfigured(Map<String, Object?> evidence) async {
  final path =
      Platform.environment['CONCLAVE_TEST_FULL_LOCAL_ACCESS_EVIDENCE_DIR'];
  if (path == null || path.isEmpty) return;
  final directory = Directory(path);
  await directory.create(recursive: true);
  final file = File('${directory.path}/full-local-access-host.json');
  await file.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(evidence)}\n');
}
