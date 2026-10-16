import 'dart:io';

/// Repository root, resolved from the `apps/workspace` test working directory.
String get repositoryRoot => Directory.current.parent.parent.path;
