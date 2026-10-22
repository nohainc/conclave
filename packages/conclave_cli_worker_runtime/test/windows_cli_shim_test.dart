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
}
