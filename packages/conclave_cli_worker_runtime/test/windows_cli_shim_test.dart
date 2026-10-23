import 'dart:convert';
import 'dart:io';

import 'package:conclave_cli_worker_runtime/conclave_cli_worker_runtime.dart';
import 'package:test/test.dart';

void main() {
  test(
    'recognizes a generic npm node entry point without executing shell text',
    () {
      const shim =
          r'@echo off node.exe "%dp0%\node_modules\package\bin\cli.js" %*';
      expect(npmShimEntryPoint(shim), 'node_modules/package/bin/cli.js');
    },
  );
  test('rejects traversal, ambiguous, and arbitrary batch commands', () {
    for (final shim in [
      r'node "%dp0%\node_modules\..\secret.js" %*',
      r'node "%dp0%\node_modules\one.js" "%dp0%\node_modules\two.js" %*',
      r'echo %* & del something',
    ]) {
      expect(() => npmShimEntryPoint(shim), throwsFormatException);
    }
  });
  test(
    'Windows npm shim forwards shell metacharacters as literal Node arguments',
    () async {
      final dir = await Directory.systemTemp.createTemp('conclave-shim-');
      try {
        final script = File('${dir.path}/node_modules/package/cli.js');
        await script.parent.create(recursive: true);
        await script.writeAsString(
          'process.stdout.write(JSON.stringify(process.argv.slice(2)))',
        );
        final shim = File('${dir.path}/tool.cmd');
        await shim.writeAsString(
          r'@echo off node.exe "%dp0%\node_modules\package\cli.js" %*',
        );
        final args = [
          'a&b',
          'quote"value',
          r'%PATH%',
          r'!VAR!',
          r'$(bad)',
          'ž',
        ];
        final process = await startCliProcess(
          shim.path,
          args,
          workingDirectory: dir.path,
          environment: Platform.environment,
          includeParentEnvironment: false,
        );
        final output = process.stdout.transform(utf8.decoder).join();
        final errors = process.stderr.transform(utf8.decoder).join();
        expect(await process.exitCode, 0, reason: await errors);
        expect(jsonDecode(await output), args);
      } finally {
        await dir.delete(recursive: true);
      }
    },
    skip: !Platform.isWindows,
  );
}
