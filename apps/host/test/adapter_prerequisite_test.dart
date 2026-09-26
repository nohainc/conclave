import 'dart:io';

import 'package:conclave_host/adapter_prerequisite.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('prerequisite manifest accepts only bounded command names', () {
    final parsed = AdapterExecutablePrerequisite.fromJson({
      'kind': 'executable',
      'executable': 'codex',
      'minimumVersion': '1.2.3',
      'versionArgs': ['--version'],
    });
    expect(parsed.executable, 'codex');
    expect(parsed.minimumVersion, '1.2.3');
    expect(
      () => AdapterExecutablePrerequisite.fromJson({
        'kind': 'executable',
        'executable': '../codex',
      }),
      throwsFormatException,
    );
    expect(
      () => AdapterExecutablePrerequisite.fromJson({
        'kind': 'executable',
        'executable': 'codex',
        'unexpected': true,
      }),
      throwsFormatException,
    );
  });

  test('probes an installed command and enforces version bounds', () async {
    final executableName = Platform.isWindows ? 'dart.exe' : 'dart';
    final available = await probeAdapterExecutable(
      AdapterExecutablePrerequisite(
        executable: executableName,
        versionArgs: const ['--version'],
        minimumVersion: '0.0.1',
        maximumVersion: '99.0.0',
      ),
      searchPath: Platform.environment['PATH'],
    );
    expect(available.satisfied, isTrue, reason: available.message);
    expect(available.detectedVersion, isNotNull);

    final tooNew = await probeAdapterExecutable(
      AdapterExecutablePrerequisite(
        executable: executableName,
        versionArgs: const ['--version'],
        maximumVersion: '1.0.0',
      ),
      searchPath: Platform.environment['PATH'],
    );
    expect(tooNew.satisfied, isFalse);
    expect(tooNew.message, contains('newer than supported'));
  });

  test('missing executables produce a local remediation state', () async {
    final result = await probeAdapterExecutable(
      const AdapterExecutablePrerequisite(executable: 'conclave-missing-tool'),
      searchPath: '',
    );
    expect(result.satisfied, isFalse);
    expect(result.message, contains('not available'));
  });
}
