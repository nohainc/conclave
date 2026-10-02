import 'dart:async';
import 'dart:io';

import 'package:conclave_workspace/friendly_computer_name.dart';
import 'package:conclave_workspace/platform_runtime.dart';
import 'package:test/test.dart';

class _MockPlatformRuntime implements PlatformRuntime {
  _MockPlatformRuntime({required this.operatingSystem, this.isWindows = false});

  @override
  final String operatingSystem;
  @override
  final bool isWindows;
  @override
  String get homeDirectory => '/tmp';
  @override
  Future<void> restrictPermissions(String path,
      {required bool directory}) async {}
  @override
  List<StreamSubscription<ProcessSignal>> watchTermination(
          void Function() onTermination) =>
      [];
  @override
  Future<Process> startIsolatedProcess(
          String executable, List<String> arguments,
          {String? workingDirectory,
          Map<String, String>? environment,
          bool includeParentEnvironment = true}) =>
      throw UnimplementedError();
  @override
  Future<void> terminateProcessTree(Process process,
      {required bool force}) async {}
}

void main() {
  group('resolveFriendlyComputerName', () {
    test('macOS uses scutil --get ComputerName result when available',
        () async {
      final macPlatform = _MockPlatformRuntime(operatingSystem: 'macos');
      final name = await resolveFriendlyComputerName(
        platform: macPlatform,
        runCommand: (executable, args) async {
          expect(executable, 'scutil');
          expect(args, ['--get', 'ComputerName']);
          return ProcessResult(1234, 0, "Vitalii's MacBook Pro\n", '');
        },
        localHostname: 'Vitaliis-MacBook-Pro.local',
      );

      expect(name, "Vitalii's MacBook Pro");
    });

    test('macOS falls back to cleaned hostname when scutil fails', () async {
      final macPlatform = _MockPlatformRuntime(operatingSystem: 'macos');
      final name = await resolveFriendlyComputerName(
        platform: macPlatform,
        runCommand: (executable, args) async =>
            ProcessResult(1234, 1, '', 'command not found'),
        localHostname: 'Vitaliis-MacBook-Pro.local',
      );

      expect(name, 'Vitaliis-MacBook-Pro');
    });

    test(
        'macOS falls back to "My Mac" when scutil fails and hostname is localhost',
        () async {
      final macPlatform = _MockPlatformRuntime(operatingSystem: 'macos');
      final name = await resolveFriendlyComputerName(
        platform: macPlatform,
        runCommand: (executable, args) async =>
            ProcessResult(1234, 1, '', 'error'),
        localHostname: 'localhost',
      );

      expect(name, 'My Mac');
    });

    test('Windows uses COMPUTERNAME environment variable', () async {
      final winPlatform =
          _MockPlatformRuntime(operatingSystem: 'windows', isWindows: true);
      final name = await resolveFriendlyComputerName(
        platform: winPlatform,
        environment: {'COMPUTERNAME': 'DEV-RIG-01'},
        localHostname: 'DESKTOP-ABC1234.lan',
      );

      expect(name, 'DEV-RIG-01');
    });

    test('Windows falls back to cleaned hostname when COMPUTERNAME is missing',
        () async {
      final winPlatform =
          _MockPlatformRuntime(operatingSystem: 'windows', isWindows: true);
      final name = await resolveFriendlyComputerName(
        platform: winPlatform,
        environment: {},
        localHostname: 'DESKTOP-ABC1234.lan',
      );

      expect(name, 'DESKTOP-ABC1234');
    });

    test(
        'Windows falls back to "My PC" when COMPUTERNAME is missing and hostname is localhost',
        () async {
      final winPlatform =
          _MockPlatformRuntime(operatingSystem: 'windows', isWindows: true);
      final name = await resolveFriendlyComputerName(
        platform: winPlatform,
        environment: {},
        localHostname: 'localhost',
      );

      expect(name, 'My PC');
    });

    test('Linux uses hostnamectl --pretty when available', () async {
      final linuxPlatform = _MockPlatformRuntime(operatingSystem: 'linux');
      final name = await resolveFriendlyComputerName(
        platform: linuxPlatform,
        runCommand: (executable, args) async {
          expect(executable, 'hostnamectl');
          expect(args, ['--pretty']);
          return ProcessResult(1234, 0, 'Ubuntu Workstation\n', '');
        },
        localHostname: 'ubuntu-box.local',
      );

      expect(name, 'Ubuntu Workstation');
    });

    test(
        'Linux reads PRETTY_HOSTNAME from /etc/machine-info when hostnamectl fails',
        () async {
      final linuxPlatform = _MockPlatformRuntime(operatingSystem: 'linux');
      final name = await resolveFriendlyComputerName(
        platform: linuxPlatform,
        runCommand: (executable, args) async =>
            ProcessResult(1234, 1, '', 'not supported'),
        readFile: (path) {
          if (path == '/etc/machine-info') {
            return 'PRETTY_HOSTNAME="Data Center Worker Node"\nDEPLOYMENT=production\n';
          }
          return null;
        },
        localHostname: 'node-99.internal',
      );

      expect(name, 'Data Center Worker Node');
    });

    test(
        'Linux falls back to cleaned hostname when pretty sources are unavailable',
        () async {
      final linuxPlatform = _MockPlatformRuntime(operatingSystem: 'linux');
      final name = await resolveFriendlyComputerName(
        platform: linuxPlatform,
        runCommand: (executable, args) async =>
            ProcessResult(1234, 1, '', 'not supported'),
        readFile: (path) => null,
        localHostname: 'ci-runner-42.localdomain',
      );

      expect(name, 'ci-runner-42');
    });

    test(
        'Linux falls back to "My Workspace" when all fail and hostname is localhost',
        () async {
      final linuxPlatform = _MockPlatformRuntime(operatingSystem: 'linux');
      final name = await resolveFriendlyComputerName(
        platform: linuxPlatform,
        runCommand: (executable, args) async =>
            ProcessResult(1234, 1, '', 'error'),
        readFile: (path) => null,
        localHostname: 'localhost',
      );

      expect(name, 'My Workspace');
    });
  });

  group('resolveFriendlyComputerNameSync', () {
    test('Windows resolves COMPUTERNAME synchronously', () {
      final winPlatform =
          _MockPlatformRuntime(operatingSystem: 'windows', isWindows: true);
      final name = resolveFriendlyComputerNameSync(
        platform: winPlatform,
        environment: {'COMPUTERNAME': 'WORKSTATION-X'},
      );

      expect(name, 'WORKSTATION-X');
    });

    test('Linux resolves PRETTY_HOSTNAME from file synchronously', () {
      final linuxPlatform = _MockPlatformRuntime(operatingSystem: 'linux');
      final name = resolveFriendlyComputerNameSync(
        platform: linuxPlatform,
        readFile: (path) => 'PRETTY_HOSTNAME=Office-Desktop\n',
      );

      expect(name, 'Office-Desktop');
    });

    test('Strips network domain suffixes from hostnames', () {
      final macPlatform = _MockPlatformRuntime(operatingSystem: 'macos');
      expect(
        resolveFriendlyComputerNameSync(
          platform: macPlatform,
          localHostname: 'Alex-MacBook.local',
        ),
        'Alex-MacBook',
      );
      expect(
        resolveFriendlyComputerNameSync(
          platform: macPlatform,
          localHostname: 'Alex-MacBook.lan',
        ),
        'Alex-MacBook',
      );
      expect(
        resolveFriendlyComputerNameSync(
          platform: macPlatform,
          localHostname: 'Alex-MacBook.localdomain',
        ),
        'Alex-MacBook',
      );
    });
  });
}
