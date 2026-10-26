import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'workspace_configuration.dart';
import 'linux_service_manager.dart';
import 'macos_service_manager.dart';
import 'windows_service_manager.dart';
import 'workspace_background_service.dart';
import 'workspace_manager_ipc.dart';
import 'workspace_settings.dart';

typedef WorkspaceCliRequest =
    Future<Object?> Function(String command, Map<String, Object?> payload);

/// Management CLI for a running Workspace service. It only speaks the local
/// authenticated IPC protocol: it never starts Engines, provider CLIs, or
/// talks to Cloud (ADR-021 §2.6).
class WorkspaceCli {
  WorkspaceCli({
    required this.out,
    required this.err,
    WorkspaceCliRequest? request,
    WorkspaceServiceManager Function(Directory)? hostManager,
    ({String email, String password}) Function()? readCredentials,
  })  : _request = request,
        _hostManager = hostManager,
        _readCredentials = readCredentials;

  final StringSink out;
  final StringSink err;
  final WorkspaceCliRequest? _request;
  final WorkspaceServiceManager Function(Directory)? _hostManager;
  final ({String email, String password}) Function()? _readCredentials;

  static const usage = '''
Usage: conclave-workspace [--data-dir DIR] [--json] <command>

  service install|uninstall|start|stop|restart|status
                            Manage host background service (macOS/Linux/Windows)
  config init|show|validate|path
                            Manage the restart-applied workspace.nano file
  login [status|cancel]     Browser approval and Cloud registration
  login --password         Sign in with existing Cloud email/password
  setup                    Start service, sign in and connect (headless)
  status                    Service summary (connection, workers, slots)
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
  folders [list]            List allowed Space folders
  folders add PATH [--name NAME]
                            Add an allowed Space folder
  folders remove ID         Remove an allowed Space folder
  metrics | logs
  updates                   Show which updater manages this installation
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
    if (rest.length == 2 && rest.first == 'config') {
      return _config(dataDir, rest[1], json);
    }
    if ((rest.length == 1 && rest.first == 'setup') ||
        (rest.length == 2 && rest[0] == 'login' && rest[1] == '--password')) {
      return _passwordLogin(dataDir, json, setup: rest.first == 'setup');
    }
    if (rest.length >= 2 && rest.first == 'folders' && rest[1] != 'list') {
      return _folders(dataDir, rest.sublist(1), json);
    }
    final call = _resolve(rest);
    if (call == null) {
      err.write(usage);
      return 64;
    }
    try {
      final result = await _send(dataDir, call.$1, call.$2);
      if (call.$1 == 'connection.connect') {
        await _updateConnectionSetting(dataDir, true);
      } else if (call.$1 == 'connection.disconnect') {
        await _updateConnectionSetting(dataDir, false);
      }
      if (!json && result is Map<String, Object?>) {
        if (call.$1 == 'service.getStatus') {
          _printStatusSummary(result);
          return 0;
        }
        if (call.$1 == 'connection.connect' ||
            call.$1 == 'connection.reconnect' ||
            call.$1 == 'connection.disconnect' ||
            call.$1 == 'connection.pause' ||
            call.$1 == 'connection.resume') {
          _printConnectionSummary(call.$1, result);
          return 0;
        }
      }
      _print(result, json);
      return 0;
    } on WorkspaceManagerProtocolException catch (error) {
      err.writeln('conclave-workspace: ${error.message} (${error.code})');
      return 1;
    } on TimeoutException {
      err.writeln('conclave-workspace: service request timed out.');
      return 69;
    } on SocketException {
      err.writeln(
        'conclave-workspace: the Workspace service is not running '
        'or its socket is unreachable.',
      );
      return 69;
    } on FileSystemException catch (error) {
      err.writeln(
        'conclave-workspace: cannot read service state '
        '(${error.path}). Is the service installed for this user?',
      );
      return 69;
    }
  }

  Future<int> _passwordLogin(
    String? dataDir,
    bool json, {
    required bool setup,
  }) async {
    try {
      if (setup) {
        final root = WorkspaceConfigurationResolver.resolveDataDirectory([
          if (dataDir != null) ...['--data-dir', dataDir],
        ]);
        await WorkspaceSettingsStore(root).ensureDefaults();
        if (await _service(dataDir, 'install', json) != 0 ||
            await _service(dataDir, 'start', json) != 0) {
          return 1;
        }
        var ready = false;
        for (var attempt = 0; attempt < 40; attempt++) {
          try {
            final health = await _send(dataDir, 'service.getHealth', {});
            if (health is Map && health['healthy'] == true) {
              ready = true;
              break;
            }
          } on Object {
            /* Wait for authenticated IPC during startup. */
          }
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        if (!ready) {
          err.writeln(
            'Service did not become healthy. Run conclave-workspace health.',
          );
          return 69;
        }
        final snapshot = await _send(dataDir, 'service.getStatus', {});
        if (snapshot is Map &&
            snapshot['workspace'] is Map &&
            (snapshot['workspace'] as Map)['workspaceId'] != null) {
          return await _finishConnection(dataDir, json);
        }
      }
      final ({String email, String password}) credentials;
      if (_readCredentials != null) {
        credentials = _readCredentials();
      } else {
        final terminal = stdin.hasTerminal;
        if (terminal) err.write('Cloud email: ');
        final email = stdin.readLineSync() ?? '';
        final oldEcho = terminal ? stdin.echoMode : true;
        String password;
        try {
          if (terminal) {
            err.write('Cloud password: ');
            stdin.echoMode = false;
          }
          password = stdin.readLineSync() ?? '';
        } finally {
          if (terminal) {
            stdin.echoMode = oldEcho;
            err.writeln();
          }
        }
        credentials = (email: email, password: password);
      }
      if (credentials.email.trim().isEmpty || credentials.password.isEmpty) {
        err.writeln('Cloud email and password are required.');
        return 64;
      }
      await _send(dataDir, 'auth.start', {
        'email': credentials.email.trim(),
        'password': credentials.password,
      });
      for (var attempt = 0; attempt < 120; attempt++) {
        final status = await _send(dataDir, 'auth.status', {});
        if (status is Map && status['phase'] == 'complete') {
          await _synchronizeRegistrationSettings(dataDir);
          if (setup) return await _finishConnection(dataDir, json);
          _print(status, json);
          return 0;
        }
        if (status is Map && status['phase'] != 'pending') {
          _print(status, json);
          return 1;
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      err.writeln('Sign-in is pending. Run conclave-workspace login status.');
      return 69;
    } on WorkspaceManagerProtocolException catch (error) {
      err.writeln('conclave-workspace: ${error.message} (${error.code})');
      return 1;
    } on Object {
      // Never render exceptions that may contain the private login payload.
      err.writeln(
        'Headless sign-in failed. Check service health and login status.',
      );
      return 1;
    }
  }

  Future<int> _finishConnection(String? dataDir, bool json) async {
    await _send(dataDir, 'connection.connect', {});
    for (var attempt = 0; attempt < 60; attempt++) {
      final snapshot = await _send(dataDir, 'service.getStatus', {});
      if (snapshot is Map &&
          snapshot['cloud'] is Map &&
          (snapshot['cloud'] as Map)['synchronized'] == true) {
        await _updateConnectionSetting(dataDir, true);
        _print({
          'phase': 'complete',
          'message': 'Workspace is online. No Workers are required.',
        }, json);
        err.writeln(
          'For startup without login: sudo loginctl enable-linger ${Platform.environment['USER'] ?? '<user>'}',
        );
        return 0;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    err.writeln(
      'Registered, but Cloud is not ready. Run conclave-workspace status.',
    );
    return 69;
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
      case ('folders', 'list'):
        return ('folders.list', {});
      case ('updates', null):
        return ('updates.status', {});
      case ('metrics', null):
        return ('diagnostics.getMetrics', {});
      case ('logs', null):
        return ('diagnostics.getLogs', {});
    }
    return null;
  }

  Future<Object?> _send(
    String? dataDir,
    String command,
    Map<String, Object?> payload,
  ) async {
    final request = _request;
    if (request != null) return request(command, payload);
    final root = WorkspaceConfigurationResolver.resolveDataDirectory([
      if (dataDir != null) ...['--data-dir', dataDir],
    ]);
    final runtime = Directory('${root.path}/runtime');
    final key = (await File(
      '${runtime.path}/manager-ipc.key',
    ).readAsString()).trim();
    final client = await WorkspaceManagerIpcClient.connect(
      socketPath: workspaceManagerEndpoint(runtime),
      key: key,
    );
    try {
      return await client.request(
        command,
        payload: payload,
        timeout: const Duration(seconds: 60),
      );
    } finally {
      await client.close();
    }
  }

  Future<int> _service(String? dataDir, String action, bool json) async {
    if (!const {
      'install',
      'uninstall',
      'start',
      'stop',
      'restart',
      'status',
    }.contains(action)) {
      err.write(usage);
      return 64;
    }
    final root = WorkspaceConfigurationResolver.resolveDataDirectory([
      if (dataDir != null) ...['--data-dir', dataDir],
    ]);
    final manager =
        _hostManager?.call(root) ??
        (Platform.isMacOS
            ? MacOsWorkspaceServiceManager(dataDirectory: root)
            : Platform.isWindows
                ? WindowsWorkspaceServiceManager(dataDirectory: root)
                : LinuxWorkspaceServiceManager(dataDirectory: root));
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
      if (json) {
        _print({
          'registration': info.registration.name,
          'process': info.process.name,
          'pid': info.pid,
        }, true);
      } else {
        final registered = info.registration == ServiceInstallationState.registered;
        final running = info.process == ServiceRuntimeState.running;
        final registrationText = registered ? 'Installed' : 'Not installed';
        final processText = running ? 'Running (pid: ${info.pid})' : 'Stopped';
        out.writeln('Service:       $registrationText');
        out.writeln('Status:        $processText');
        if (!registered) {
          out.writeln('Hint:          Run conclave-workspace service install');
        } else if (!running) {
          out.writeln('Hint:          Run conclave-workspace service start');
        }
      }
      return 0;
    } on Object catch (error) {
      err.writeln('conclave-workspace: $error');
      return 1;
    }
  }

  Future<int> _config(String? dataDir, String action, bool json) async {
    if (!const {'init', 'show', 'validate', 'path'}.contains(action)) {
      err.write(usage);
      return 64;
    }
    final root = WorkspaceConfigurationResolver.resolveDataDirectory([
      if (dataDir != null) ...['--data-dir', dataDir],
    ]);
    final store = WorkspaceSettingsStore(root);
    try {
      if (action == 'path') {
        out.writeln(store.file.absolute.path);
        return 0;
      }
      if (action == 'init') {
        await store.ensureDefaults();
      }
      final settings = store.readSync();
      if (settings == null) {
        err.writeln(
          'workspace.nano does not exist. Run conclave-workspace config init.',
        );
        return 66;
      }
      if (action == 'show') {
        if (json) {
          _print(settings.toNanoValue(), true);
        } else {
          out.write(store.file.readAsStringSync());
        }
      } else {
        _print({
          'valid': true,
          'path': store.file.absolute.path,
          'version': WorkspaceSettings.schemaVersion,
          'restartRequiredToApply': true,
        }, json);
      }
      return 0;
    } on Object catch (error) {
      err.writeln('conclave-workspace: invalid workspace.nano: $error');
      return 65;
    }
  }

  Future<void> _synchronizeRegistrationSettings(String? dataDir) async {
    final root = WorkspaceConfigurationResolver.resolveDataDirectory([
      if (dataDir != null) ...['--data-dir', dataDir],
    ]);
    final registration = WorkspaceRegistrationStore(root).readSync();
    if (registration == null) return;
    final store = WorkspaceSettingsStore(root);
    final settings = await store.ensureDefaults();
    await store.write(
      settings.copyWith(
        cloudUrl: registration.cloudUrl,
        workspaceName: registration.name,
      ),
    );
  }

  Future<void> _updateConnectionSetting(String? dataDir, bool connected) async {
    final root = WorkspaceConfigurationResolver.resolveDataDirectory([
      if (dataDir != null) ...['--data-dir', dataDir],
    ]);
    final store = WorkspaceSettingsStore(root);
    final settings = await store.ensureDefaults();
    if (settings.connectOnStart != connected) {
      await store.write(settings.copyWith(connectOnStart: connected));
    }
  }

  Future<int> _folders(String? dataDir, List<String> args, bool json) async {
    if (args.isEmpty) {
      err.write(usage);
      return 64;
    }
    final action = args[0];
    if (action == 'remove' && args.length == 2) {
      try {
        final result = await _send(dataDir, 'folders.remove', {'folderId': args[1]});
        _print(result, json);
        return 0;
      } on WorkspaceManagerProtocolException catch (error) {
        err.writeln('conclave-workspace: ${error.message} (${error.code})');
        return 1;
      }
    }
    if (action == 'add' && args.length >= 2) {
      final path = args[1];
      String? name;
      for (var i = 2; i < args.length; i++) {
        if (args[i] == '--name' && i + 1 < args.length) {
          name = args[++i];
        }
      }
      try {
        final result = await _send(dataDir, 'folders.add', {
          'path': path,
          if (name != null) 'displayName': name,
        });
        _print(result, json);
        return 0;
      } on WorkspaceManagerProtocolException catch (error) {
        err.writeln('conclave-workspace: ${error.message} (${error.code})');
        return 1;
      }
    }
    err.write(usage);
    return 64;
  }

  void _printStatusSummary(Map<String, Object?> snapshot) {
    final workspace = snapshot['workspace'] as Map<String, Object?>? ?? const {};
    final cloud = snapshot['cloud'] as Map<String, Object?>? ?? const {};
    final service = snapshot['service'] as Map<String, Object?>? ?? const {};
    final assignments = snapshot['assignments'] as Map<String, Object?>? ?? const {};
    final workers = (snapshot['workers'] as List?)?.length ?? 0;

    final name = workspace['name'] ?? 'Workspace';
    final cloudState = cloud['state'] ?? 'offline';
    final connected = cloud['connected'] == true;
    final cloudUrl = cloud['transport'] != null ? '${cloud['transport']} (${cloud['lifecycleState']})' : '${cloud['lifecycleState'] ?? cloudState}';
    final workRoot = workspace['workRoot'] ?? 'Not configured';
    final activeCount = assignments['activeCount'] ?? 0;
    final healthy = service['serviceHealthy'] == true;

    out.writeln('Workspace:     $name (${healthy ? 'healthy' : 'unhealthy'})');
    out.writeln('Cloud:         ${connected ? 'Connected' : 'Disconnected'} ($cloudUrl)');
    out.writeln('Work Root:     $workRoot');
    out.writeln('Workers:       $workers configured');
    out.writeln('Active Work:   $activeCount running');
  }

  void _printConnectionSummary(String command, Map<String, Object?> snapshot) {
    final cloud = snapshot['cloud'] as Map<String, Object?>? ?? const {};
    final connected = cloud['connected'] == true;
    final state = cloud['lifecycleState'] ?? cloud['state'] ?? 'offline';
    final accepting = cloud['acceptingNewWork'] == true;

    switch (command) {
      case 'connection.connect' || 'connection.reconnect':
        out.writeln(connected ? 'Cloud:         Connected ($state)' : 'Cloud:         Connecting ($state)...');
      case 'connection.disconnect':
        out.writeln('Cloud:         Disconnected');
      case 'connection.pause':
        out.writeln('Cloud:         Paused (not accepting new work)');
      case 'connection.resume':
        out.writeln(accepting ? 'Cloud:         Resumed (accepting work)' : 'Cloud:         Resumed');
      default:
        out.writeln('Cloud:         $state');
    }
  }

  void _print(Object? result, bool json) {
    if (result is Map && result['text'] is String && !json) {
      out.writeln(result['text']);
    } else {
      out.writeln(
        const JsonEncoder.withIndent('  ').convert(result ?? {'ok': true}),
      );
    }
  }
}
