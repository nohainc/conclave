import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conclave_workspace/cli_worker_engine_supervisor.dart';
import 'package:conclave_workspace/tool_profile_release_verifier.dart';
import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

void main() {
  test('reaps only registered Engine processes after restart', () async {
    if (Platform.isWindows) return;
    final root = await Directory.systemTemp.createTemp('engine-recovery-');
    addTearDown(() => root.delete(recursive: true));
    try {
      final psProbe = await Process.run('ps', ['-p', '1', '-o', 'pid=']);
      if (psProbe.exitCode != 0) return;
    } on ProcessException {
      return;
    }
    final state = Directory('${root.path}/worker-state');
    await state.create();
    final process = await Process.start(
      '/bin/sh',
      [
        '-c',
        'while :; do sleep 30; done',
        'conclave-engine-test',
        '--state-directory',
        state.path
      ],
    );
    final registry = Directory('${root.path}/runtime');
    await registry.create();
    await File('${registry.path}/assignment.worker-process.json')
        .writeAsString(jsonEncode({
      'pid': process.pid,
      'executable': File('/bin/sh').absolute.path,
      'stateDirectory': state.path,
    }));
    final supervisor = CliWorkerEngineSupervisor(
      engineExecutable: '/bin/sh',
      processRegistryDirectory: registry,
    );

    expect(await supervisor.recoverOrphanedProcesses(), 1);
    await process.exitCode.timeout(const Duration(seconds: 2));
  });

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
      throwsA(isA<Object>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(await setup.supervisor.cancel('queued'), isTrue);
    await queuedExpectation;
    expect((await first).output, 'first');
  });

  test('cancelling a queued assignment does not release the active slot',
      () async {
    final setup = await _setup();
    addTearDown(() => setup.root.delete(recursive: true));
    final first = _execute(setup, 'first', prompt: 'slow');
    await _waitFor(File('${setup.state.path}/active').existsSync);
    final cancelled = _execute(setup, 'cancelled');
    final cancelledExpectation = expectLater(
      cancelled,
      throwsA(isA<WorkerAssignmentCancelledException>()),
    );
    final waiting = _execute(setup, 'waiting');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(await setup.supervisor.cancel('cancelled'), isTrue);
    await cancelledExpectation;
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(File('${setup.state.path}/active').readAsStringSync(), 'first');
    expect((await first).output, 'slow');
    expect((await waiting).output, 'waiting');
    expect(File('${setup.state.path}/max-active').existsSync(), isFalse);
  });

  test('times out while waiting for the Worker concurrency slot', () async {
    final setup = await _setup();
    addTearDown(() => setup.root.delete(recursive: true));
    final first = _execute(setup, 'first', prompt: 'slow');
    await _waitFor(File('${setup.state.path}/active').existsSync);
    await expectLater(
      _execute(
        setup,
        'queued-timeout',
        timeout: const Duration(seconds: 1),
        queueWaitTimeout: const Duration(seconds: 1),
      ),
      throwsA(isA<CliWorkerEngineProbeException>().having(
          (error) => error.localDiagnostics,
          'diagnostics',
          allOf(contains('queue_wait'), contains('local_startup')))),
    );
    expect((await first).output, 'slow');
  });

  test('does not consume execution timeout while queued', () async {
    final setup = await _setup();
    addTearDown(() => setup.root.delete(recursive: true));
    final first = _execute(setup, 'first', prompt: 'slow');
    await _waitFor(File('${setup.state.path}/active').existsSync);
    final queued = _execute(
      setup,
      'queued',
      timeout: const Duration(seconds: 1),
      queueWaitTimeout: const Duration(seconds: 7),
    );
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(await first, isA<WorkerResult>());
    expect((await queued).output, 'queued');
  });

  test('runs independent assignments concurrently up to the effective limit',
      () async {
    final setup = await _setup();
    addTearDown(() => setup.root.delete(recursive: true));
    final first = _execute(
      setup,
      'first',
      prompt: 'slow',
      maxConcurrentAssignments: 2,
    );
    final second = _execute(
      setup,
      'second',
      prompt: 'slow',
      maxConcurrentAssignments: 2,
    );
    await _waitFor(File('${setup.state.path}/max-active').existsSync);
    final third = _execute(
      setup,
      'third',
      maxConcurrentAssignments: 2,
    );
    expect((await first).output, 'slow');
    expect((await second).output, 'slow');
    expect((await third).output, 'third');
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
      throwsA(isA<Object>()),
    );
  });

  test('Engine exit before a terminal frame releases the Worker slot',
      () async {
    final setup = await _setup();
    addTearDown(() => setup.root.delete(recursive: true));
    await expectLater(
      _execute(setup, 'exited', prompt: 'exit'),
      throwsA(isA<CliWorkerEngineProbeException>()),
    );
    expect((await _execute(setup, 'after-exit')).output, 'after-exit');
  });

  test('records durable ownership metadata while an Engine is active',
      () async {
    final setup = await _setup();
    addTearDown(() => setup.root.delete(recursive: true));
    final execution = _execute(setup, 'metadata', prompt: 'slow');
    await _waitFor(() => setup.registry
        .listSync()
        .whereType<File>()
        .any((file) => file.path.endsWith('.worker-process.json')));
    final recordFile = setup.registry
        .listSync()
        .whereType<File>()
        .singleWhere((file) => file.path.endsWith('.worker-process.json'));
    final record = Map<String, Object?>.from(
      jsonDecode(await recordFile.readAsString()) as Map,
    );
    expect(record['assignmentId'], 'metadata');
    expect(record['attemptId'], 'attempt-metadata');
    expect(record['workerId'], 'worker-1');
    expect(record['enginePid'], isA<int>());
    expect(record['localExecutionId'], isA<String>());
    expect(record['deadlineAt'], isA<String>());
    expect(record['providerState'], 'not_started');
    await setup.supervisor.cancel('metadata');
    await expectLater(execution, throwsA(isA<Object>()));
  });

  test('a cancellation issued right after execute() prevents process creation',
      () async {
    final setup = await _setup();
    addTearDown(() => setup.root.delete(recursive: true));
    final execution = _execute(setup, 'immediate');
    final expectation = expectLater(
      execution,
      throwsA(isA<WorkerAssignmentCancelledException>()),
    );
    // No await between execute() and cancel(): the assignment must already be
    // visible to cancellation.
    expect(await setup.supervisor.cancel('immediate'), isTrue);
    await expectation;
    expect(File('${setup.state.path}/active').existsSync(), isFalse);
    expect(setup.supervisor.activeAssignmentCountFor('worker-1'), 0);
    expect((await _execute(setup, 'after')).output, 'after');
  });

  test('a failing slot-reserved callback neither leaks the slot nor blocks',
      () async {
    final setup = await _setup();
    addTearDown(() => setup.root.delete(recursive: true));
    expect(
      (await _execute(setup, 'throws',
              onSlotReserved: () => throw StateError('diagnostic failed')))
          .output,
      'throws',
    );
    expect(
      (await _execute(setup, 'async-throws',
              onSlotReserved: () async => throw StateError('write failed')))
          .output,
      'async-throws',
    );
    expect(setup.supervisor.activeAssignmentCountFor('worker-1'), 0);
  });

  test('a slow slot-reserved callback does not delay the Engine launch',
      () async {
    final setup = await _setup();
    addTearDown(() => setup.root.delete(recursive: true));
    final blocker = Completer<void>();
    addTearDown(() {
      if (!blocker.isCompleted) blocker.complete();
    });
    final result =
        await _execute(setup, 'fast', onSlotReserved: () => blocker.future)
            .timeout(const Duration(seconds: 5));
    expect(result.output, 'fast');
  });

  test('an Engine that cannot start releases capacity and is classified',
      () async {
    final setup = await _setup();
    addTearDown(() => setup.root.delete(recursive: true));
    final broken = CliWorkerEngineSupervisor(
      engineExecutable: '${setup.root.path}/missing-engine',
      processRegistryDirectory: setup.registry,
    );
    for (final id in ['first', 'second']) {
      await expectLater(
        _execute(setup, id, supervisor: broken)
            .timeout(const Duration(seconds: 3)),
        throwsA(isA<CliWorkerEngineProbeException>()),
      );
      expect(broken.activeAssignmentCountFor('worker-1'), 0);
    }
    expect(broken.queuedAssignmentCount, 0);
    expect(
      setup.registry
          .listSync()
          .where((entity) => entity.path.endsWith('.worker-process.json')),
      isEmpty,
    );
  });

  test('reports the queue position when an assignment has to wait', () async {
    final setup = await _setup();
    addTearDown(() => setup.root.delete(recursive: true));
    final first = _execute(setup, 'first', prompt: 'slow');
    await _waitFor(File('${setup.state.path}/active').existsSync);
    WorkerQueueSnapshot? snapshot;
    final second = _execute(setup, 'second', onQueued: (queue) {
      snapshot = queue;
    });
    expect(snapshot?.position, 1);
    expect(snapshot?.active, 1);
    expect(snapshot?.limit, 1);
    expect(snapshot?.waitingForSession, isFalse);
    expect(setup.supervisor.queuedAssignmentCountFor('worker-1'), 1);
    await setup.supervisor.cancel('first');
    await expectLater(first, throwsA(isA<Object>()));
    expect((await second).output, 'second');
    expect(setup.supervisor.queuedAssignmentCountFor('worker-1'), 0);
  });

  test('raising the Worker limit admits waiting assignments before newcomers',
      () async {
    final setup = await _setup();
    addTearDown(() => setup.root.delete(recursive: true));
    final first = _execute(setup, 'first', prompt: 'slow');
    await _waitFor(File('${setup.state.path}/active').existsSync);
    final started = <String>[];
    final second = _execute(setup, 'second', onSlotReserved: () {
      started.add('second');
    });
    expect(setup.supervisor.queuedAssignmentCountFor('worker-1'), 1);
    final third = _execute(setup, 'third', maxConcurrentAssignments: 2,
        onSlotReserved: () {
      started.add('third');
    });
    await Future.wait([second, third]);
    expect(started.first, 'second');
    await setup.supervisor.cancel('first');
    await expectLater(first, throwsA(isA<Object>()));
  });

  test('never runs two assignments on the same native session at once',
      () async {
    final setup = await _setup();
    addTearDown(() => setup.root.delete(recursive: true));
    final first = _execute(setup, 'first',
        prompt: 'slow', sessionKey: 'native-1', maxConcurrentAssignments: 2);
    await _waitFor(File('${setup.state.path}/active').existsSync);
    WorkerQueueSnapshot? snapshot;
    final sameSession = _execute(setup, 'same-session',
        sessionKey: 'native-1',
        maxConcurrentAssignments: 2,
        onQueued: (queue) => snapshot = queue);
    expect(snapshot?.waitingForSession, isTrue);
    expect(setup.supervisor.activeAssignmentCountFor('worker-1'), 1);
    // An unrelated session of the same Worker is not blocked by that wait.
    expect(
      (await _execute(setup, 'other-session',
              sessionKey: 'native-2', maxConcurrentAssignments: 2))
          .output,
      'other-session',
    );
    expect(setup.supervisor.queuedAssignmentCountFor('worker-1'), 1);
    // Once the first assignment ends, the waiting one runs.
    await setup.supervisor.cancel('first');
    await expectLater(first, throwsA(isA<Object>()));
    expect((await sameSession).output, 'same-session');
    expect(setup.supervisor.activeAssignmentCountFor('worker-1'), 0);
  });

  test('the ownership record is durable before the provider is asked to start',
      () async {
    final setup = await _setup();
    addTearDown(() => setup.root.delete(recursive: true));
    final execution = _execute(setup, 'record-first', prompt: 'slow');
    // The fake Engine creates `active` when it receives execute.request, so
    // by then the record must already exist.
    await _waitFor(File('${setup.state.path}/active').existsSync);
    expect(
      setup.registry
          .listSync()
          .where((entity) => entity.path.endsWith('.worker-process.json')),
      hasLength(1),
    );
    await setup.supervisor.cancel('record-first');
    await expectLater(execution, throwsA(isA<Object>()));
  });

  test('rejects duplicate local execution for the same assignment', () async {
    final setup = await _setup();
    addTearDown(() => setup.root.delete(recursive: true));
    final first = _execute(setup, 'duplicate', prompt: 'slow');
    await _waitFor(File('${setup.state.path}/active').existsSync);
    await expectLater(
      _execute(setup, 'duplicate'),
      throwsA(isA<FormatException>()),
    );
    await setup.supervisor.cancel('duplicate');
    await expectLater(first, throwsA(isA<Object>()));
  });
}

Future<WorkerResult> _execute(
  _Setup setup,
  String assignmentId, {
  String? prompt,
  Duration timeout = const Duration(seconds: 10),
  Duration? queueWaitTimeout,
  int maxConcurrentAssignments = 1,
  String? sessionKey,
  FutureOr<void> Function()? onSlotReserved,
  void Function(WorkerQueueSnapshot queue)? onQueued,
  CliWorkerEngineSupervisor? supervisor,
}) =>
    (supervisor ?? setup.supervisor).execute(
      setup.admission,
      profileFile: setup.profileFile,
      stateDirectory: setup.state,
      workingDirectory: setup.thread,
      workerId: 'worker-1',
      maxConcurrentAssignments: maxConcurrentAssignments,
      assignmentId: assignmentId,
      attemptId: setup.attemptId,
      prompt: prompt ?? assignmentId,
      timeout: timeout,
      queueWaitTimeout: queueWaitTimeout,
      sessionPolicy: sessionKey == null
          ? WorkerSessionPolicy.stateless
          : WorkerSessionPolicy.durableSession,
      sessionKey: sessionKey,
      onSlotReserved: onSlotReserved,
      onQueued: onQueued,
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
  final thread = await Directory('${root.path}/thread').create();
  final registry = await Directory('${root.path}/registry').create();
  final script = File('${root.path}/fake_engine.dart')
    ..writeAsStringSync(_fakeEngineSource);
  return _Setup(
    root: root,
    profileFile: profileFile,
    admission: admission,
    state: state,
    thread: thread,
    supervisor: CliWorkerEngineSupervisor(
      engineExecutable: _testDartExecutable(),
      engineArgumentsPrefix: [script.path],
      processRegistryDirectory: registry,
    ),
    registry: registry,
    attemptId: 'attempt-metadata',
  );
}

String _testDartExecutable() {
  final configured = Platform.environment['DART_EXECUTABLE'];
  if (configured != null && configured.isNotEmpty) return configured;
  try {
    final lookup = Process.runSync(
      Platform.isWindows ? 'where' : 'which',
      ['dart'],
    );
    if (lookup.exitCode == 0) {
      final executable = lookup.stdout
          .toString()
          .split(RegExp(r'\r?\n'))
          .map((line) => line.trim())
          .firstWhere((line) => line.isNotEmpty, orElse: () => '');
      if (executable.isNotEmpty) return executable;
    }
  } on Object {
    // Fall back to the current runtime when the Dart executable is not on PATH.
  }
  return Platform.resolvedExecutable;
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
    required this.thread,
    required this.supervisor,
    required this.registry,
    required this.attemptId,
  });

  final Directory root;
  final File profileFile;
  final ToolProfileReleaseAdmission admission;
  final Directory state;
  final Directory thread;
  final CliWorkerEngineSupervisor supervisor;
  final Directory registry;
  final String attemptId;
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
          'engineVersion': valueAfter(args, '--engine-version'),
          'profileDefinitionId': profile['profileDefinitionId'],
          'profileReleaseVersion': '${profile['releaseVersion']}',
          'profileSchemaVersion': profile['schemaVersion'],
          'capabilities': <String>[],
        }));
      case 'execute.request':
        if (request['prompt'] == 'exit') exit(17);
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
