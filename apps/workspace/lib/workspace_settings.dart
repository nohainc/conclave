import 'dart:io';

import 'package:nanomarkup/nanomarkup.dart' as nano;

import 'local_worker_permissions.dart';
import 'platform_runtime.dart';
import 'work_root.dart';

/// Versioned, non-secret desired configuration for the Workspace service.
///
/// Nano Markup deliberately keeps every scalar as text. This application
/// layer owns boolean, integer, URI and path validation so configuration has
/// identical semantics on Linux, macOS and Windows.
final class WorkspaceSettings {
  const WorkspaceSettings({
    required this.serviceEnabled,
    required this.cloudUrl,
    required this.connectOnStart,
    required this.workspaceName,
    required this.parallelSlots,
    required this.workRoot,
    this.folders = const {},
  });

  static const schemaVersion = 1;

  final bool serviceEnabled;
  final String cloudUrl;
  final bool connectOnStart;
  final String workspaceName;
  final int parallelSlots;

  /// The primary Work Root path where worker runs and scratch workspaces live.
  final String workRoot;

  /// Optional named project folders mapped locally.
  final Map<String, String> folders;

  String get workRootPath => workRoot;

  WorkspaceSettings copyWith({
    bool? serviceEnabled,
    String? cloudUrl,
    bool? connectOnStart,
    String? workspaceName,
    int? parallelSlots,
    String? workRoot,
    Map<String, String>? folders,
  }) {
    final updatedFolders = folders ?? this.folders;
    return WorkspaceSettings(
      serviceEnabled: serviceEnabled ?? this.serviceEnabled,
      cloudUrl: cloudUrl ?? this.cloudUrl,
      connectOnStart: connectOnStart ?? this.connectOnStart,
      workspaceName: workspaceName ?? this.workspaceName,
      parallelSlots: parallelSlots ?? this.parallelSlots,
      workRoot: workRoot ?? (folders != null && folders.containsKey('work') ? folders['work']! : this.workRoot),
      folders: Map.unmodifiable(updatedFolders),
    );
  }

  Map<String, Object> toNanoValue() => <String, Object>{
    'version': schemaVersion.toString(),
    'service': <String, Object>{'enabled': serviceEnabled.toString()},
    'cloud': <String, Object>{
      'url': cloudUrl,
      'connect_on_start': connectOnStart.toString(),
    },
    'workspace': <String, Object>{
      'name': workspaceName,
      'work_root': workRoot,
    },
    'execution': <String, Object>{'parallel_slots': parallelSlots.toString()},
    if (folders.isNotEmpty) 'folders': <String, Object>{...folders},
  };

  factory WorkspaceSettings.fromNanoValue(
    Object value, {
    Directory? dataDirectory,
    PlatformRuntime? platform,
  }) {
    if (value is! Map) {
      throw const FormatException('Workspace configuration must be a mapping');
    }
    final root = Map<String, Object>.from(value);
    _onlyKeys(root, const {
      'version',
      'service',
      'cloud',
      'workspace',
      'execution',
      'folders',
    }, 'configuration');
    if (_requiredString(root, 'version', 'configuration') !=
        schemaVersion.toString()) {
      throw const FormatException(
        'Unsupported Workspace configuration version',
      );
    }
    final service = _mapping(root, 'service');
    final cloud = _mapping(root, 'cloud');
    final workspace = _mapping(root, 'workspace');
    final execution = _mapping(root, 'execution');
    _onlyKeys(service, const {'enabled'}, 'service');
    _onlyKeys(cloud, const {'url', 'connect_on_start'}, 'cloud');
    _onlyKeys(workspace, const {'name', 'work_root'}, 'workspace');
    _onlyKeys(execution, const {'parallel_slots'}, 'execution');

    final cloudUrl = _requiredString(cloud, 'url', 'cloud');
    final uri = Uri.tryParse(cloudUrl);
    if (uri == null ||
        !const {'http', 'https', 'ws', 'wss'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException(
        'cloud.url must be an HTTP(S) or WebSocket origin without credentials',
      );
    }
    final name = _requiredString(workspace, 'name', 'workspace').trim();
    if (name.isEmpty || name.length > 120) {
      throw const FormatException(
        'workspace.name must contain between 1 and 120 characters',
      );
    }
    final slots = int.tryParse(
      _requiredString(execution, 'parallel_slots', 'execution'),
    );
    if (slots == null || slots < minParallelSlots || slots > maxParallelSlots) {
      throw const FormatException(
        'execution.parallel_slots must be between $minParallelSlots and $maxParallelSlots',
      );
    }

    String? workRoot = workspace['work_root'] as String?;
    if (workRoot != null) {
      if (!_isAbsolutePath(workRoot)) {
        throw const FormatException('workspace.work_root must be an absolute path');
      }
    }

    final folders = <String, String>{};
    if (root.containsKey('folders')) {
      final folderValues = _mapping(root, 'folders');
      for (final entry in folderValues.entries) {
        final path = entry.value;
        if (path is! String || !_isAbsolutePath(path)) {
          throw FormatException('folders.${entry.key} must be an absolute path');
        }
        folders[entry.key] = path;
      }
    }
    // Backward-compatibility: if legacy work folder was specified in folders instead
    if (workRoot == null && folders.containsKey('work')) {
      workRoot = folders['work'];
    }

    final runtime = platform ?? currentPlatformRuntime;
    workRoot ??= WorkRootResolver(platform: runtime).defaultPath;

    return WorkspaceSettings(
      serviceEnabled: _boolean(service, 'enabled'),
      cloudUrl: cloudUrl,
      connectOnStart: _boolean(cloud, 'connect_on_start'),
      workspaceName: name,
      parallelSlots: slots,
      workRoot: workRoot,
      folders: Map.unmodifiable(folders),
    );
  }

  static WorkspaceSettings defaults({
    required Directory dataDirectory,
    PlatformRuntime? platform,
  }) {
    final runtime = platform ?? currentPlatformRuntime;
    final work = WorkRootResolver(platform: runtime).defaultPath;
    return WorkspaceSettings(
      serviceEnabled: true,
      cloudUrl: 'https://app.conclaveax.com',
      connectOnStart: false,
      workspaceName: 'Workspace',
      parallelSlots: defaultLocalWorkerConcurrency,
      workRoot: Directory(work).absolute.path,
      folders: const {},
    );
  }

  static Map<String, Object> _mapping(Map<String, Object> parent, String key) {
    final value = parent[key];
    if (value is! Map) {
      throw FormatException('$key must be a mapping');
    }
    return Map<String, Object>.from(value);
  }

  static String _requiredString(
    Map<String, Object> value,
    String key,
    String section,
  ) {
    final result = value[key];
    if (result is! String || result.isEmpty) {
      throw FormatException('$section.$key is required');
    }
    return result;
  }

  static bool _boolean(Map<String, Object> value, String key) {
    return switch (_requiredString(value, key, key)) {
      'true' => true,
      'false' => false,
      _ => throw FormatException('$key must be true or false'),
    };
  }

  static void _onlyKeys(
    Map<String, Object> value,
    Set<String> allowed,
    String section,
  ) {
    final unknown = value.keys.where((key) => !allowed.contains(key)).toList();
    if (unknown.isNotEmpty) {
      throw FormatException('$section contains unknown key ${unknown.first}');
    }
  }

  static bool _isAbsolutePath(String value) =>
      value.startsWith('/') ||
      RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value) ||
      value.startsWith(r'\\');
}

/// Atomic reader/writer for `<state>/workspace.nano`.
final class WorkspaceSettingsStore {
  WorkspaceSettingsStore(this.dataDirectory, {PlatformRuntime? platform})
    : platform = platform ?? currentPlatformRuntime;

  final Directory dataDirectory;
  final PlatformRuntime platform;
  static int _temporaryCounter = 0;

  File get file =>
      File('${dataDirectory.path}${Platform.pathSeparator}workspace.nano');

  WorkspaceSettings? readSync() {
    if (!file.existsSync()) return null;
    final value = nano.decodeBytes(file.readAsBytesSync());
    return WorkspaceSettings.fromNanoValue(
      value,
      dataDirectory: dataDirectory,
      platform: platform,
    );
  }

  Future<void> write(WorkspaceSettings settings) async {
    await dataDirectory.create(recursive: true);
    await platform.restrictPermissions(dataDirectory.path, directory: true);
    final temporary = File('${file.path}.tmp.$pid.${++_temporaryCounter}');
    try {
      await temporary.writeAsString(
        '${nano.encode(settings.toNanoValue())}\n',
        flush: true,
      );
      await platform.restrictPermissions(temporary.path, directory: false);
      await temporary.rename(file.path);
    } on Object {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  Future<WorkspaceSettings> ensureDefaults() async {
    final existing = readSync();
    if (existing != null) return existing;
    final settings = WorkspaceSettings.defaults(
      dataDirectory: dataDirectory,
      platform: platform,
    );
    await write(settings);
    return settings;
  }
}
