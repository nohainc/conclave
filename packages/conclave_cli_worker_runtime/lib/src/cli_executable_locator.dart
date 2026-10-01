import 'dart:convert';
import 'dart:io';

/// Resolves a Profile-declared command without a shell.
///
/// Profile locations are searched first, followed by conservative OS-wide
/// installation locations, then PATH when the Profile permits PATH search.
/// A cached path is revalidated on every use.
class CliExecutableLocator {
  const CliExecutableLocator();

  static const maxPathLength = 4096;
  static const maxPathEntries = 32;
  static const maxSearchDirectories = 64;
  static const maxCacheBytes = 8 * 1024;

  Future<String?> locate(
    String executable, {
    Map<String, String>? environment,
    String? cachedPath,
    Iterable<String> standardPaths = const [],
    int pathEntryLimit = maxPathEntries,
    File? cacheFile,
    String? cacheIdentity,
  }) async {
    if (!_validExecutableName(executable)) return null;
    final env = environment ?? Platform.environment;
    final names = _executableNames(executable);
    final directories = <String>[
      ...standardPaths,
      ..._osBaselinePaths(env),
      ..._pathDirectories(env, pathEntryLimit),
    ];
    final unique = <String>{};
    final boundedDirectories = <String>[];
    for (final directory in directories) {
      if (!_validDirectory(directory) || !unique.add(directory)) continue;
      boundedDirectories.add(directory);
      if (boundedDirectories.length == maxSearchDirectories) break;
    }

    var cached = cachedPath;
    if (cacheFile != null && cacheIdentity != null) {
      cached ??= await _readCachedPath(cacheFile, cacheIdentity);
    }
    if (cached != null &&
        _validCachedCandidate(cached, names, boundedDirectories) &&
        await _isExecutablePath(cached)) {
      return File(cached).absolute.path;
    }

    for (final directory in boundedDirectories) {
      for (final name in names) {
        final path = '$directory${Platform.pathSeparator}$name';
        if (!_validPath(path) || !await _isExecutablePath(path)) continue;
        final resolved = File(path).absolute.path;
        if (cacheFile != null && cacheIdentity != null) {
          await _writeCachedPath(cacheFile, cacheIdentity, resolved);
        }
        return resolved;
      }
    }
    return null;
  }

  List<String> _executableNames(String executable) =>
      Platform.isWindows && !executable.contains('.')
      ? ['$executable.exe', executable]
      : [executable];

  bool _validExecutableName(String value) =>
      value.length <= 128 &&
      RegExp(r'^[A-Za-z0-9._+-]+$').hasMatch(value) &&
      !value.contains('/') &&
      !value.contains('\\');

  List<String> _osBaselinePaths(Map<String, String> environment) {
    final home = _homeDirectory(environment);
    final locations = <String>[];
    void addHome(String child) {
      if (home != null) locations.add('$home${Platform.pathSeparator}$child');
    }

    addHome('.local${Platform.pathSeparator}bin');
    addHome('.npm-global${Platform.pathSeparator}bin');
    addHome('.npm${Platform.pathSeparator}bin');
    addHome('.volta${Platform.pathSeparator}bin');
    addHome('.bun${Platform.pathSeparator}bin');
    if (Platform.isMacOS) {
      locations.addAll(const ['/opt/homebrew/bin', '/usr/local/bin']);
    } else if (Platform.isLinux) {
      addHome('.cargo${Platform.pathSeparator}bin');
      locations.addAll(const [
        '/usr/local/bin',
        '/usr/bin',
        '/bin',
        '/snap/bin',
      ]);
    } else if (Platform.isWindows) {
      final appData = environment['APPDATA'];
      final localAppData = environment['LOCALAPPDATA'];
      if (_validPathRoot(appData)) {
        locations.add('$appData${Platform.pathSeparator}npm');
      }
      if (_validPathRoot(localAppData)) {
        locations.add(
          '$localAppData${Platform.pathSeparator}Microsoft'
          '${Platform.pathSeparator}WinGet${Platform.pathSeparator}Links',
        );
        locations.add('$localAppData${Platform.pathSeparator}Programs');
      }
      locations.addAll(const [r'C:\Program Files\nodejs']);
    }
    if (!Platform.isWindows) locations.addAll(const ['/usr/bin', '/bin']);
    return locations;
  }

  String? _homeDirectory(Map<String, String> environment) {
    final candidates = Platform.isWindows
        ? [environment['USERPROFILE'], environment['HOME']]
        : [environment['HOME']];
    for (final value in candidates) {
      if (_validPathRoot(value)) return value;
    }
    return null;
  }

  List<String> _pathDirectories(
    Map<String, String> environment,
    int requestedLimit,
  ) {
    final path = environment['PATH'];
    if (path == null || path.length > maxPathLength * maxPathEntries) {
      return const [];
    }
    final limit = requestedLimit.clamp(0, maxPathEntries);
    return path
        .split(Platform.isWindows ? ';' : ':')
        .where(_validDirectory)
        .take(limit)
        .toList(growable: false);
  }

  bool _validPathRoot(String? path) =>
      path != null && _validPath(path) && File(path).isAbsolute;

  bool _validDirectory(String path) =>
      _validPath(path) && File(path).isAbsolute;

  bool _validPath(String path) =>
      path.isNotEmpty &&
      path.length <= maxPathLength &&
      !path.contains('\u0000');

  bool _validCachedCandidate(
    String path,
    List<String> names,
    List<String> approvedDirectories,
  ) {
    if (!_validPath(path) ||
        !File(path).isAbsolute ||
        !names.contains(path.split(Platform.pathSeparator).last)) {
      return false;
    }
    final directory = path.substring(
      0,
      path.lastIndexOf(Platform.pathSeparator),
    );
    return approvedDirectories.contains(directory);
  }

  Future<String?> _readCachedPath(File cacheFile, String identity) async {
    if (!_validIdentity(identity)) return null;
    final type = await FileSystemEntity.type(
      cacheFile.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) return null;
    try {
      final length = await cacheFile.length();
      if (length < 1 || length > maxCacheBytes) return null;
      final decoded = jsonDecode(await cacheFile.readAsString());
      if (decoded is! Map ||
          decoded['schemaVersion'] != 1 ||
          decoded['identity'] != identity ||
          decoded['path'] is! String) {
        return null;
      }
      return decoded['path'] as String;
    } on Object {
      return null;
    }
  }

  Future<void> _writeCachedPath(
    File cacheFile,
    String identity,
    String path,
  ) async {
    if (!_validIdentity(identity) || !_validPath(path)) return;
    await cacheFile.parent.create(recursive: true);
    final parentType = await FileSystemEntity.type(
      cacheFile.parent.path,
      followLinks: false,
    );
    final cacheType = await FileSystemEntity.type(
      cacheFile.path,
      followLinks: false,
    );
    if (parentType != FileSystemEntityType.directory ||
        (cacheType != FileSystemEntityType.notFound &&
            cacheType != FileSystemEntityType.file)) {
      return;
    }
    final temporary = File(
      '${cacheFile.path}.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await temporary.writeAsString(
        jsonEncode({'schemaVersion': 1, 'identity': identity, 'path': path}),
        flush: true,
      );
      if (cacheType == FileSystemEntityType.file) {
        await cacheFile.delete();
      }
      await temporary.rename(cacheFile.path);
    } on Object {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  bool _validIdentity(String identity) =>
      identity.isNotEmpty &&
      identity.length <= 256 &&
      RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(identity);

  Future<bool> _isExecutablePath(String path) async {
    if (!_validPath(path)) return false;
    final file = File(path);
    if (!file.isAbsolute) return false;
    try {
      final type = await FileSystemEntity.type(path, followLinks: true);
      return type == FileSystemEntityType.file &&
          (Platform.isWindows || await _isExecutable(file));
    } on FileSystemException {
      return false;
    }
  }

  Future<bool> _isExecutable(File file) async {
    final mode = (await file.stat()).mode;
    // POSIX user/group/other executable bits.
    return (mode & 0x49) != 0;
  }
}
