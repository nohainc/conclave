import 'dart:io';

class CliExecutableLocator {
  const CliExecutableLocator();

  Future<String?> locate(
    String executable, {
    Map<String, String>? environment,
    String? cachedPath,
    Iterable<String> additionalPaths = const [],
    Iterable<String> standardPaths = const [],
    int pathEntryLimit = 32,
  }) async {
    if (executable.trim().isEmpty ||
        executable.contains(Platform.pathSeparator)) {
      return null;
    }
    final pathEntries = (environment ?? Platform.environment)['PATH'] ?? '';
    final candidates = <String>[
      if (cachedPath != null && cachedPath.trim().isNotEmpty)
        _directoryOf(cachedPath),
      ...pathEntries
          .split(Platform.isWindows ? ';' : ':')
          .where((part) => part.isNotEmpty)
          .take(pathEntryLimit),
      ...additionalPaths,
      ...standardPaths,
    ];
    if (cachedPath != null && await _isExecutablePath(cachedPath)) {
      return File(cachedPath).absolute.path;
    }
    final names = Platform.isWindows && !executable.contains('.')
        ? ['$executable.exe', '$executable.cmd', executable]
        : [executable];
    for (final directory in candidates) {
      for (final name in names) {
        final file = File('$directory${Platform.pathSeparator}$name');
        if (await file.exists() &&
            (Platform.isWindows || await _isExecutable(file))) {
          return file.absolute.path;
        }
      }
    }
    return null;
  }

  String _directoryOf(String path) {
    final separator = Platform.pathSeparator;
    final index = path.lastIndexOf(separator);
    return index < 0 ? '.' : path.substring(0, index);
  }

  Future<bool> _isExecutablePath(String path) async {
    final file = File(path);
    return file.isAbsolute &&
        await file.exists() &&
        (Platform.isWindows || await _isExecutable(file));
  }

  Future<bool> _isExecutable(File file) async {
    final mode = (await file.stat()).mode;
    // POSIX user/group/other executable bits.
    return (mode & 0x49) != 0;
  }
}
