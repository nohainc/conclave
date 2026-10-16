import 'dart:io';

String get repositoryRoot => File('pubspec.yaml').existsSync()
    ? Directory.current.parent.parent.path
    : Directory.current.path;
