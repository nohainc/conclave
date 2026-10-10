import 'dart:async';
import 'dart:io';

import 'package:conclave_workspace/main.dart';
import 'package:conclave_workspace/secure_credentials.dart';
import 'package:conclave_workspace/workspace.dart';
import 'package:conclave_workspace/workspace_manager_ipc.dart';
import 'package:flutter_test/flutter_test.dart';

class _HostManager implements WorkspaceServiceManager {
  int registrations = 0;
  int starts = 0;
  Future<void> Function()? onRegistration;
  WorkspaceServiceInfo info = const WorkspaceServiceInfo(
    registration: WorkspaceBackgroundServiceRegistration.registered,
    supported: true,
    helperPresent: true,
    plistPresent: true,
    launchdState: 'stopped',
  );
  @override
  Future<WorkspaceServiceInfo> getInfo() async => info;

  @override
  Future<WorkspaceServiceInfo> status() => getInfo();
  @override
  Future<WorkspaceServiceInfo> register() async {
    registrations++;
    final action = onRegistration;
    if (action != null) unawaited(action());
    return status();
  }

  @override
  Future<WorkspaceServiceInfo> unregister() => getInfo();
  @override
  Future<WorkspaceServiceInfo> start() async {
    starts++;
    return info;
  }

  @override
  Future<WorkspaceServiceInfo> stop() => getInfo();

  @override
  Future<WorkspaceServiceInfo> restart() => getInfo();
  @override
  Future<void> openSettings() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Directory runtime;
  late WorkspaceLifecycleController lifecycle;
  late _HostManager host;
  setUp(() async {
    root = await Directory('/tmp').createTemp('ws-startup-');
    runtime = Directory('${root.path}/runtime');
    host = _HostManager();
    lifecycle = WorkspaceLifecycleController(
      WorkspaceConfig(dataDirectory: root),
      credentialStore: const PlatformSecureCredentialStore(),
      serviceManager: host,
      startupTimeout: const Duration(milliseconds: 100),
      startupRetryDelay: const Duration(milliseconds: 5),
    );
  });
  tearDown(() async {
    await lifecycle.quit();
    await root.delete(recursive: true);
  });

  WorkspaceManagerIpcServer server(
          {Future<Map<String, Object?>> Function()? snapshot}) =>
      WorkspaceManagerIpcServer(
        runtimeDirectory: runtime,
        serviceVersion: 'startup-test',
        snapshotProvider: snapshot ??
            () async => {
                  'service': {'processState': 'ready'},
                  'cloud': {'connected': false},
                },
        requestHandler: (_, __) async => null,
      );

  test('missing key can appear later and the next attempt attaches', () async {
    await lifecycle.launch();
    expect(lifecycle.running, isFalse);
    expect(lifecycle.startupError, isA<FileSystemException>());
    final service = server();
    await service.start();
    try {
      await lifecycle.launch();
      expect(lifecycle.running, isTrue);
      expect(lifecycle.startupError, isNull);
    } finally {
      await lifecycle.quit();
      await service.close();
    }
  });

  test(
      'failed socket attempt is disposed before retrying a newly ready service',
      () async {
    await runtime.create();
    await File('${runtime.path}/manager-ipc.key').writeAsString('0' * 64);
    await lifecycle.launch();
    expect(lifecycle.running, isFalse);
    expect(lifecycle.startupError, isA<SocketException>());
    final service = server();
    await service.start();
    try {
      // Must succeed immediately; no wait for a retained client's retry timer.
      await lifecycle.launch();
      expect(lifecycle.running, isTrue);
      expect(lifecycle.startupError, isNull);
    } finally {
      await lifecycle.quit();
      await service.close();
    }
  });

  test('failed handshake retries with the refreshed capability key', () async {
    final service = server();
    await service.start();
    try {
      final keyFile = File('${runtime.path}/manager-ipc.key');
      final correctKey = await keyFile.readAsString();
      await keyFile.writeAsString('f' * 64);
      await lifecycle.launch();
      expect(lifecycle.running, isFalse);
      expect(lifecycle.startupError, isA<WorkspaceManagerProtocolException>());
      await keyFile.writeAsString(correctKey);
      await lifecycle.launch();
      expect(lifecycle.running, isTrue);
    } finally {
      await lifecycle.quit();
      await service.close();
    }
  });

  test('concurrent startup attempts create one authenticated client', () async {
    var greetings = 0;
    final service = server(snapshot: () async {
      greetings++;
      return {
        'service': {'processState': 'ready'}
      };
    });
    await service.start();
    try {
      await Future.wait([lifecycle.launch(), lifecycle.launch()]);
      expect(lifecycle.running, isTrue);
      expect(greetings, 1);
    } finally {
      await lifecycle.quit();
      await service.close();
    }
  });

  test('startup wait retries while the registered service becomes ready',
      () async {
    final service = server();
    Future<void>? starting;
    host.onRegistration = () => starting =
        Future<void>.delayed(const Duration(milliseconds: 20), service.start);
    try {
      await lifecycle.ensureBackgroundService();
      expect(lifecycle.running, isTrue);
      expect(host.registrations, 1);
      expect(host.starts, 1);
    } finally {
      await starting;
      await lifecycle.quit();
      await service.close();
    }
  });

  test('never-ready service reports an IPC timeout and operational diagnostics',
      () async {
    host.info = const WorkspaceServiceInfo(
      registration: WorkspaceBackgroundServiceRegistration.registered,
      supported: true,
      helperPresent: true,
      plistPresent: true,
      launchdState: 'running',
      process: WorkspaceServiceProcessStatus.running,
      lastExitCode: 7,
      lastExitReason: 'OS_REASON_CODESIGNING',
    );
    await expectLater(
        lifecycle.ensureBackgroundService(),
        throwsA(isA<TimeoutException>().having((error) => error.message,
            'message', contains('could not connect to it'))));
    expect(lifecycle.running, isFalse);
    expect(lifecycle.uiSnapshot.serviceDiagnostics,
        containsPair('launchd', 'running'));
    expect(lifecycle.uiSnapshot.serviceDiagnostics,
        containsPair('IPC key', 'Missing'));
    expect(lifecycle.uiSnapshot.serviceDiagnostics,
        containsPair('IPC socket', 'Missing'));
    expect(lifecycle.uiSnapshot.serviceDiagnostics,
        containsPair('Service exit code', '7'));
    expect(lifecycle.uiSnapshot.serviceDiagnostics,
        containsPair('Service exit reason', 'OS_REASON_CODESIGNING'));
    expect(lifecycle.uiSnapshot.issue, contains('Last IPC error:'));
    expect(lifecycle.uiSnapshot.issue, isNot(contains('did not start')));
    expect(host.registrations, 0);
    expect(host.starts, 1);
  });

  test('launchd failure is reported before waiting for an IPC timeout',
      () async {
    host.info = const WorkspaceServiceInfo(
      registration: WorkspaceBackgroundServiceRegistration.registered,
      supported: true,
      helperPresent: true,
      plistPresent: true,
      launchdState: 'not running',
      process: WorkspaceServiceProcessStatus.failed,
      lastExitCode: 9,
      lastExitReason: 'OS_REASON_CODESIGNING',
    );

    await expectLater(
      lifecycle.ensureBackgroundService(),
      throwsA(isA<StateError>().having(
        (error) => error.message,
        'message',
        contains('OS_REASON_CODESIGNING'),
      )),
    );
    expect(host.starts, 1);
    expect(lifecycle.uiSnapshot.serviceInfo.process,
        WorkspaceServiceProcessStatus.failed);
  });

  test('unsigned development bundle explains why launchd cannot start it',
      () async {
    host.info = const WorkspaceServiceInfo(
      registration: WorkspaceBackgroundServiceRegistration.notRegistered,
      supported: true,
      helperPresent: true,
      plistPresent: true,
      launchSupported: false,
    );
    await expectLater(
      lifecycle.ensureBackgroundService(),
      throwsA(isA<StateError>().having(
        (error) => error.message,
        'message',
        contains('not signed for macOS background service execution'),
      )),
    );
    expect(host.registrations, 0);
    expect(host.starts, 0);
  });

  test('already-running service attaches without native registration',
      () async {
    host.info = host.info.copyWith(
      launchdState: 'running',
      process: WorkspaceServiceProcessStatus.running,
    );
    final service = server();
    await service.start();
    try {
      await lifecycle.ensureBackgroundService();
      expect(lifecycle.running, isTrue);
      expect(host.registrations, 0);
      expect(host.starts, 0);
    } finally {
      await lifecycle.quit();
      await service.close();
    }
  });
}
