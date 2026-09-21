import 'dart:io';
import 'package:conclave_agent_engine/runtime_capabilities.dart';
import 'package:test/test.dart';

void main() {
  test('blocks traversal and permits contained files', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-runtime-');
    final workspace = SafeWorkspace(directory);
    await workspace.write('src/main.txt', 'hello');
    expect(await workspace.read('src/main.txt'), 'hello');
    expect(() => workspace.read('../secret'), throwsA(isA<RuntimeViolation>()));
    await directory.delete(recursive: true);
  });

  test('enforces command allowlist and output policy', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-runtime-');
    final runner = SafeCommandRunner(SafeWorkspace(directory));
    final result = await runner.run(['printf', 'hello'],
        policy: const CommandPolicy(allowedExecutables: {'printf'}));
    expect(result.exitCode, 0);
    expect(result.stdout, 'hello');
    expect(
        () => runner.run(['sh', '-c', 'echo unsafe'],
            policy: const CommandPolicy(allowedExecutables: {'printf'})),
        throwsA(isA<RuntimeViolation>()));
    expect(
        () => runner.run(['printf', 'safe; echo unsafe'],
            policy: const CommandPolicy(allowedExecutables: {'printf'})),
        throwsA(isA<RuntimeViolation>()));
    expect(
        () => runner.run(['printf', 'anything'],
            policy: CommandPolicy(
              allowedExecutables: {'printf'},
              allowedArgumentPatterns: {
                'printf': [RegExp(r'^safe$')],
              },
            )),
        throwsA(isA<RuntimeViolation>()));
    await directory.delete(recursive: true);
  });

  test('terminates a command that exceeds the output limit', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-runtime-');
    final runner = SafeCommandRunner(SafeWorkspace(directory));
    final result = await runner.run(
      ['yes'],
      policy: const CommandPolicy(
        allowedExecutables: {'yes'},
        maxOutputBytes: 32,
        timeout: Duration(seconds: 5),
      ),
    );
    expect(result.stdout.length, lessThanOrEqualTo(32));
    await directory.delete(recursive: true);
  });

  test('redacts configured secrets from command evidence', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-runtime-');
    final runner = SafeCommandRunner(SafeWorkspace(directory));
    final result = await runner.run(
      ['printf', 'token-123'],
      policy: const CommandPolicy(
        allowedExecutables: {'printf'},
        secretValues: {'token-123'},
      ),
    );
    expect(result.stdout, '[REDACTED]');
    await directory.delete(recursive: true);
  });

  test('produces stable artifact hashes', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-runtime-');
    final file = File('${directory.path}/artifact.txt')
      ..writeAsStringSync('same');
    final artifact = await stageArtifact(file);
    expect(artifact.sizeBytes, 4);
    expect(artifact.sha256,
        '0967115f2813a3541eaef77de9d9d5773f1c0c04314b0bbfe4ff3b3b1c55b5d5');
    await directory.delete(recursive: true);
  });
}
