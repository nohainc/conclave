import 'dart:async';
import 'dart:io';

import 'package:conclave_host/platform_runtime.dart';
import 'package:conclave_host/work_root.dart';
import 'package:test/test.dart';

class FakePlatform implements PlatformRuntime {
  FakePlatform(this.operatingSystem, this.homeDirectory);

  @override
  final String operatingSystem;
  @override
  final String homeDirectory;

  @override
  bool get isWindows => operatingSystem == 'windows';

  final List<String> restricted = [];

  @override
  Future<void> restrictPermissions(String path,
      {required bool directory}) async {
    restricted.add(path);
  }

  @override
  List<StreamSubscription<ProcessSignal>> watchTermination(
          void Function() onTermination) =>
      [];

  @override
  Future<Process> startIsolatedProcess(
          String executable, List<String> arguments,
          {String? workingDirectory, Map<String, String>? environment}) async =>
      throw UnimplementedError();

  @override
  Future<void> terminateProcessTree(Process process,
      {required bool force}) async {}
}

class FailingPermissionPlatform extends FakePlatform {
  FailingPermissionPlatform(super.operatingSystem, super.homeDirectory);

  @override
  Future<void> restrictPermissions(String path,
      {required bool directory}) async {
    throw const FileSystemException('permission denied');
  }
}

void main() {
  test('selects platform-appropriate defaults without Workspace IDs', () {
    expect(
        WorkRootResolver(platform: FakePlatform('macos', '/home/tester'))
            .defaultPath,
        '/home/tester/Library/Application Support/Conclave/Work');
    expect(
        WorkRootResolver(platform: FakePlatform('linux', '/home/tester'))
            .defaultPath,
        '/home/tester/.local/share/conclave/work');
    expect(
        WorkRootResolver(platform: FakePlatform('windows', 'C:\\Users\\tester'))
            .defaultPath,
        'C:\\Users\\tester\\AppData\\Local\\Conclave\\Work');
  });

  test('creates and canonicalizes a custom root with hardened permissions',
      () async {
    final parent = await Directory.systemTemp.createTemp('conclave-work-root-');
    addTearDown(() => parent.delete(recursive: true));
    final platform = FakePlatform('linux', parent.path);
    final requested = Directory('${parent.path}/nested/../work');
    final resolved = await WorkRootResolver(
      platform: platform,
      overridePath: requested.path,
    ).resolve();

    expect(await resolved.exists(), isTrue);
    expect(platform.restricted, contains(resolved.path));
    expect(resolved.path, isNot(contains('..')));
  });

  test('rejects a root change while active Workstream work exists', () async {
    final parent = await Directory.systemTemp.createTemp('conclave-work-root-');
    addTearDown(() => parent.delete(recursive: true));
    await expectLater(
      WorkRootResolver(
        platform: FakePlatform('linux', parent.path),
        overridePath: '${parent.path}/new-root',
      ).resolve(hasActiveWork: true),
      throwsA(isA<WorkRootViolation>()),
    );
  });

  test('uses no Workspace enrollment identity and survives re-enrollment',
      () async {
    final parent = await Directory.systemTemp.createTemp('conclave-work-root-');
    addTearDown(() => parent.delete(recursive: true));
    final first = await WorkRootResolver(
      platform: FakePlatform('linux', parent.path),
      overridePath: '${parent.path}/stable',
    ).resolve();
    final reenrolled = await WorkRootResolver(
      platform: FakePlatform('linux', parent.path),
      overridePath: '${parent.path}/stable',
    ).resolve();

    expect(first.path, reenrolled.path);
    expect(first.path, isNot(contains('workspace-old')));
    expect(first.path, isNot(contains('workspace-new')));
  });

  test('fails when the configured root is an existing file', () async {
    final parent = await Directory.systemTemp.createTemp('conclave-work-root-');
    addTearDown(() => parent.delete(recursive: true));
    final file = File('${parent.path}/not-a-directory');
    await file.writeAsString('occupied');

    await expectLater(
      WorkRootResolver(
        platform: FakePlatform('linux', parent.path),
        overridePath: file.path,
      ).resolve(),
      throwsA(isA<WorkRootViolation>()),
    );
  });

  test('fails closed when the root cannot be permission-hardened', () async {
    final parent = await Directory.systemTemp.createTemp('conclave-work-root-');
    addTearDown(() => parent.delete(recursive: true));

    await expectLater(
      WorkRootResolver(
        platform: FailingPermissionPlatform('linux', parent.path),
        overridePath: '${parent.path}/secure',
      ).resolve(),
      throwsA(isA<WorkRootViolation>()),
    );
  });
}
