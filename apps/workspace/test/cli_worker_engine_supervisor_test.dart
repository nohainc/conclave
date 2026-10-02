import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conclave_workspace/cli_worker_engine_supervisor.dart';
import 'package:conclave_workspace/cloud_connection.dart';
import 'package:conclave_workspace/tool_profile_release_verifier.dart';
import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

void main() {
  test('serializes Engine assignments at the local Worker limit', () async {
    final setup = await _setup();
    addTearDown(() => setup.root.delete(recursive: true));
    final first = _execute(setup, 'first');
    await _waitFor(File('${setup.state.path}/active').existsSync);
    final second = _execute(setup, 'second');
    expect((await first).output, 'first');
    expect((await second).output, 'second');
    expect(File('${setup.state.path}/max-active').existsSync(), isFalse);
  });

  test('cancels a queued Engine assignment before it starts', () async {
    final setup = await _setup();
    addTearDown(() => setup.root.delete(recursive: true));
    final first = _execute(setup, 'first');
    await _waitFor(File('${setup.state.path}/active').existsSync);
    final queued = _execute(setup, 'queued');
    final queuedExpectation = expectLater(
      queued,
      throwsA(isA<AssignmentExecutionFailure>().having(
        (error) => error.code,
        'code',
        WorkerIssueCode.cancelled,
      )),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(await setup.supervisor.cancel('queued'), isTrue);
    await queuedExpectation;
    expect((await first).output, 'first');
  });

  test('cancels the active Engine process tree as an assignment failure',
      () async {
    final setup = await _setup();
    addTearDown(() => setup.root.delete(recursive: true));
    final execution = _execute(setup, 'active', prompt: 'slow');
    await _waitFor(File('${setup.state.path}/active').existsSync);
    expect(await setup.supervisor.cancel('active'), isTrue);
    await expectLater(
      execution,
      throwsA(isA<AssignmentExecutionFailure>().having(
        (error) => error.code,
        'code',
        WorkerIssueCode.cancelled,
      )),
    );
  });
}

Future<WorkerResult> _execute(
  _Setup setup,
  String assignmentId, {
  String? prompt,
}) =>
    setup.supervisor.execute(
      setup.admission,
      profileFile: setup.profileFile,
      stateDirectory: setup.state,
      workingDirectory: setup.workstream,
      workerId: 'worker-1',
      maxConcurrentAssignments: 1,
      assignmentId: assignmentId,
      prompt: prompt ?? assignmentId,
      timeout: const Duration(seconds: 10),
    );

Future<_Setup> _setup() async {
  final root = await Directory.systemTemp.createTemp('engine-supervisor-');
  final profileFile = File(
    '${Directory.current.parent.parent.path}/packages/tool-profile/test/fixtures/fixture-cli.v1.json',
  );
  final bytes = await profileFile.readAsBytes();
  final profile =
      Map<String, Object?>.from(jsonDecode(utf8.decode(bytes)) as Map);
  final provider = Map<String, Object?>.from(profile['providerTool'] as Map);
  final admission = ToolProfileReleaseAdmission(
    profile: profile,
    profileDefinitionId: profile['profileDefinitionId'] as String,
    releaseVersion: profile['releaseVersion'] as int,
    logicalWorkerTypeId: profile['logicalWorkerTypeId'] as String,
    providerToolName: provider['name'] as String,
    payloadDigest: sha256.convert(bytes).toString(),
    channel: 'stable',
  );
  final state = await Directory('${root.path}/state').create();
  final workstream = await Directory('${root.path}/workstream').create();
  final script = File('${root.path}/fake_engine.dart')
    ..writeAsStringSync(_fakeEngineSource);
  return _Setup(
    root: root,
    profileFile: profileFile,
    admission: admission,
    state: state,
    workstream: workstream,
    supervisor: CliWorkerEngineSupervisor(
      engineExecutable: Platform.environment['DART_EXECUTABLE'] ??
          Platform.environment['DART_EXECUTABLE'] ??
          Platform.resolvedExecutable,
      engineArgumentsPrefix: [script.path],
    ),
  );
}

Future<void> _waitFor(bool Function() condition) async {
  final timer = Stopwatch()..start();
  while (!condition()) {
    if (timer.elapsed > const Duration(seconds: 3)) {
      throw TimeoutException('condition was not met');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

final class _Setup {
  const _Setup({
    required this.root,
    required this.profileFile,
    required this.admission,
    required this.state,
    required this.workstream,
    required this.supervisor,
  });

  final Directory root;
  final File profileFile;
  final ToolProfileReleaseAdmission admission;
  final Directory state;
  final Directory workstream;
  final CliWorkerEngineSupervisor supervisor;
}

const _fakeEngineSource = r'''
import 'dart:async';
import 'dart:convert';
import 'dart:io';

String valueAfter(List<String> args, String key) => args[args.indexOf(key) + 1];

Future<void> main(List<String> args) async {
  final profile = jsonDecode(await File(valueAfter(args, '--profile')).readAsString()) as Map<String, dynamic>;
  final state = Directory(valueAfter(args, '--state-directory'));
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final request = jsonDecode(line) as Map<String, dynamic>;
    switch (request['type']) {
      case 'initialize.request':
        stdout.writeln(jsonEncode({
          'type': 'initialize.result',
          'protocolVersion': '4.0',
          'requestId': request['requestId'],
          'workerTypeId': profile['logicalWorkerTypeId'],
          'engineVersion': '1.0.0',
          'profileDefinitionId': profile['profileDefinitionId'],
          'profileReleaseVersion': '${profile['releaseVersion']}',
          'profileSchemaVersion': profile['schemaVersion'],
          'capabilities': profile['capabilities'],
        }));
      case 'execute.request':
        final activeFile = File('${state.path}/active');
        if (activeFile.existsSync()) {
          File('${state.path}/max-active').writeAsStringSync('2');
        }
        activeFile.writeAsStringSync(request['assignmentId'] as String);
        final slow = request['prompt'] == 'slow';
        await Future<void>.delayed(Duration(milliseconds: slow ? 5000 : 250));
        if (activeFile.existsSync() && activeFile.readAsStringSync() == request['assignmentId']) {
          activeFile.deleteSync();
        }
        stdout.writeln(jsonEncode({
          'type': 'result',
          'requestId': request['requestId'],
          'assignmentId': request['assignmentId'],
          'output': request['prompt'],
          'artifacts': <String>[],
        }));
    }
  }
}
''';
