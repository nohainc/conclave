import 'dart:convert';
import 'dart:io';

import 'package:conclave_cli_worker_runtime/src/cli_executable_locator.dart';
import 'package:test/test.dart';

void main() {
  final repository = Directory.current.parent.parent;
  late Directory temporary;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('official-cli-search-');
  });

  tearDown(() async => temporary.delete(recursive: true));

  test('finds Codex and agy from official Profiles with sparse GUI PATH', () async {
    const locator = CliExecutableLocator();
    final home = '${temporary.path}${Platform.pathSeparator}home';
    for (final (profileName, installRelativePath) in [
      ('chatgpt-codex.v1.json', '.local${Platform.pathSeparator}bin'),
      (
        'gemini-antigravity.v1.json',
        '.gemini${Platform.pathSeparator}antigravity-cli'
            '${Platform.pathSeparator}bin',
      ),
    ]) {
      final profile =
          jsonDecode(
                await File(
                  '${repository.path}/packages/tool-profile/test/fixtures/$profileName',
                ).readAsString(),
              )
              as Map<String, Object?>;
      final provider = profile['providerTool']! as Map<String, Object?>;
      final discovery = provider['discovery']! as Map<String, Object?>;
      final executable =
          (provider['executableCandidates']! as List).first as String;
      final installPath = '$home${Platform.pathSeparator}$installRelativePath';
      await Directory(installPath).create(recursive: true);
      final installedName =
          Platform.isWindows && !executable.toLowerCase().endsWith('.exe')
          ? '$executable.exe'
          : executable;
      final installed = File(
        '${installPath}${Platform.pathSeparator}$installedName',
      );
      if (Platform.isWindows) {
        await File(Platform.resolvedExecutable).copy(installed.path);
      } else {
        await Link(installed.path).create(Platform.resolvedExecutable);
      }
      final standardLocations = (discovery['standardLocations']! as List)
          .cast<String>()
          .map(
            (value) => value.startsWith('{{home}}/')
                ? '$home${Platform.pathSeparator}'
                      '${value.substring('{{home}}/'.length).replaceAll('/', Platform.pathSeparator)}'
                : value,
          )
          .toList(growable: false);

      final found = await locator.locate(
        executable,
        environment: {'HOME': home, 'PATH': ''},
        standardPaths: standardLocations,
      );
      expect(found, File(installed.path).absolute.path, reason: profileName);
    }
  });
}
