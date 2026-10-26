import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'workspace_configuration.dart';
import 'linux_service_manager.dart';
import 'workspace_background_service.dart';
import 'workspace_manager_ipc.dart';

typedef WorkspaceCliRequest = Future<Object?> Function(
  String command,
  Map<String, Object?> payload,
);

/// Management CLI for a running Workspace service. It only speaks the local
/// authenticated IPC protocol: it never starts Engines, provider CLIs, or
/// talks to Cloud (ADR-021 §2.6).
class WorkspaceCli {
  WorkspaceCli({
    required this.out,
    required this.err,
    WorkspaceCliRequest? request,
    WorkspaceServiceManager Function(Directory)? hostManager,
  })  : _request = request,
        _hostManager = hostManager;

  final StringSink out;
  final StringSink err;
  final WorkspaceCliRequest? _request;
  final WorkspaceServiceManager Function(Directory)? _hostManager;

  static const usage = '''
Usage: conclave-workspace [--data-dir DIR] [--json] <command>

  service install|uninstall|start|stop|restart|status
                            Manage this user's Linux systemd service
  login [status|cancel]     Browser approval and Cloud registration
  status                    Service snapshot (connection, workers, slots)
  health | version
  connect | disconnect      Connect or disconnect the Cloud connection
  pause | resume            Stop or resume accepting new work
  workers                   List Workers
  workers check [TYPE]      Check provider CLI readiness
  workers test ID           Run a Worker test
  workers enable|disable ID
  slots                     Parallel execution slots
  assignments               Active assignment ids
  assignments cancel ID
  folders                   Allowed folders
  metrics | logs
''';

  Future<int> run(List<String> args) async {
    final rest = <String>[];
    var json = false;
    String? dataDir;
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == '--json') {
        json = true;
      } else if (arg == '--data-dir' && i + 1 < args.length) {
        dataDir = args[++i];
      } else if (arg == '-h' || arg == '--help') {
        out.write(usage);
        return 0;
      } else {
        rest.add(arg);
      }
    }
    if (rest.length == 2 && rest.first == 'service') {
      return _service(dataDir, rest[1], json);
    }
    final call = _resolve(rest);
    if (call == null) {
      err.write(usage);
      return 64;
    }
    try {
      final result = await _send(dataDir, call.$1, call.$2);
      _print(result, json);
      return 0;
    } on WorkspaceManagerProtocolException catch (error) {
      err.writeln('conclave-workspace: ${error.message} (${error.code})');
      return 1;
    } on TimeoutException {
      err.writeln('conclave-workspace: service request timed out.');
      return 69;
    } on SocketException {
      err.writeln('conclave-workspace: the Workspace service is not running '
          'or its socket is unreachable.');
      return 69;
    } on FileSystemException catch (error) {
      err.writeln('conclave-workspace: cannot read service state '
          '(${error.path}). Is the service installed for this user?');
      return 69;
    }
  }

  (String, Map<String, Object?>)? _resolve(List<String> a) {
    if (a.isEmpty) return null;
    if (a.length > 3) {
      return null;
    }
    final id = a.length > 2 ? a[2] : null;
    if (id != null &&
        !(a.first == 'workers' ||
            (a.first == 'assignments' && a[1] == 'cancel'))) {
      return null;
    }
    switch ((a[0], a.length > 1 ? a[1] : null)) {
      case ('login', null):
        return ('auth.start', {});
      case ('login', 'status') when a.length == 2:
        return ('auth.status', {});
      case ('login', 'cancel') when a.length == 2:
        return ('auth.cancel', {});
      case ('status', null):
        return ('service.getStatus', {});
      case ('health', null):
        return ('service.getHealth', {});
      case ('version', null):
        return ('service.getVersion', {});
      case ('connect', null):
        return ('connection.connect', {});
      case ('disconnect', null):
        return ('connection.disconnect', {});
      case ('pause', null):
        return ('connection.pause', {});
      case ('resume', null):
        return ('connection.resume', {});
      case ('workers', null):
        return ('workers.list', {});
      case ('workers', 'check'):
        return ('workers.checkReadiness', {if (id != null) 'workerTypeId': id});
      case ('workers', 'test') when id != null:
        return ('workers.testWorker', {'workerId': id});
      case ('workers', 'enable') when id != null:
        return ('workers.enableWorker', {'workerId': id});
      case ('workers', 'disable') when id != null:
        return ('workers.disableWorker', {'workerId': id});
      case ('slots', null):
        return ('execution.getSlots', {});
      case ('assignments', null):
        return ('execution.listActiveAssignments', {});
      case ('assignments', 'cancel') when id != null:
        return ('execution.cancelAssignment', {'assignmentId': id});
      case ('folders', null):
        return ('folders.list', {});
      case ('metrics', null):
        return ('diagnostics.getMetrics', {});
      case ('logs', null):
        return ('diagnostics.getLogs', {});
    }
    return null;
  }

  Future<Object?> _send(
      String? dataDir, String command, Map<String, Object?> payload) async {
    final request = _request;
    if (request != null) return request(command, payload);
    final root = WorkspaceConfigurationResolver.resolveDataDirectory([
      if (dataDir != null) ...['--data-dir', dataDir]
    ]);
    final runtime = Directory('${root.path}/runtime');
    final key =
        (await File('${runtime.path}/manager-ipc.key').readAsString()).trim();
    final client = await WorkspaceManagerIpcClient.connect(
      socketPath: workspaceManagerEndpoint(runtime),
      key: key,
    );
    try {
      return await client.request(command,
          payload: payload, timeout: const Duration(seconds: 60));
    } finally {
      await client.close();
    }
  }

  Future<int> _service(String? dataDir, String action, bool json) async {
    if (!const {'install', 'uninstall', 'start', 'stop', 'restart', 'status'}
        .contains(action)) {
      err.write(usage);
      return 64;
    }
    if (_hostManager == null && !Platform.isLinux) {
      err.writeln(
          'Service commands require Linux with a systemd user session.');
      return 69;
    }
    final root = WorkspaceConfigurationResolver.resolveDataDirectory([
      if (dataDir != null) ...['--data-dir', dataDir]
    ]);
    final manager = _hostManager?.call(root) ??
        LinuxWorkspaceServiceManager(dataDirectory: root);
    try {
      if (action == 'stop' || action == 'restart' || action == 'uninstall') {
        final info = await manager.getInfo();
        if (info.processRunning) {
          await _send(dataDir, 'service.prepareStop', {});
        }
      }
      final info = await switch (action) {
        'install' => manager.register(),
        'uninstall' => manager.unregister(),
        'start' => manager.start(),
        'stop' => manager.stop(),
        'restart' => manager.restart(),
        _ => manager.getInfo(),
      };
      _print({
        'registration': info.registration.name,
        'process': info.process.name,
        'pid': info.pid
      }, json);
      return 0;
    } on Object catch (error) {
      err.writeln('conclave-workspace: $error');
      return 1;
    }
  }

  void _print(Object? result, bool json) {
    if (result is Map && result['text'] is String && !json) {
      out.writeln(result['text']);
    } else {
      out.writeln(
          const JsonEncoder.withIndent('  ').convert(result ?? {'ok': true}));
    }
  }
}
