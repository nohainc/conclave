import 'dart:io';

Future<Directory> copyForgeFixture() async {
  final repository = Directory.current.parent.parent;
  final source = Directory('${repository.path}/fixtures/conclave-e2e-fixture');
  final temporaryRoot =
      await Directory.systemTemp.createTemp('conclave-forge-fixture-');
  final destination = Directory('${temporaryRoot.path}/fixture');
  await _copyDirectory(source, destination);
  await Process.run('git', ['init', '--quiet'],
      workingDirectory: destination.path);
  await Process.run('git', ['add', '.'], workingDirectory: destination.path);
  await Process.run(
    'git',
    [
      '-c',
      'user.name=Conclave Fixture',
      '-c',
      'user.email=fixture@example.test',
      'commit',
      '--quiet',
      '-m',
      'fixture baseline',
    ],
    workingDirectory: destination.path,
  );
  return destination;
}

Future<void> _copyDirectory(Directory source, Directory destination) async {
  await destination.create(recursive: true);
  await for (final entity in source.list(followLinks: false)) {
    final name =
        entity.uri.pathSegments.where((segment) => segment.isNotEmpty).last;
    final target = '${destination.path}/$name';
    if (entity is Directory) {
      await _copyDirectory(entity, Directory(target));
    } else if (entity is File) {
      await entity.copy(target);
    }
  }
}
