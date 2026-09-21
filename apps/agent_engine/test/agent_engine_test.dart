import 'dart:io';

import 'package:conclave_agent_engine/agent_engine.dart';
import 'package:test/test.dart';

void main() {
  test('Agent Engine starts, persists state, and stops cleanly', () async {
    final directory = await Directory.systemTemp.createTemp('conclave-engine-');
    final engine =
        AgentEngine(config: AgentEngineConfig(dataDirectory: directory));

    await engine.start();
    expect(engine.isRunning, isTrue);
    expect(File('${directory.path}/engine-state.json').existsSync(), isTrue);

    await engine.stop();
    expect(engine.isRunning, isFalse);
    expect(await File('${directory.path}/engine-state.json').readAsString(),
        contains('stopped'));
    await directory.delete(recursive: true);
  });

  test('Agent Engine config reads an explicit data directory', () {
    final config =
        AgentEngineConfig.fromArgs(['--data-dir', '/tmp/conclave-agent-test']);
    expect(config.dataDirectory.path, '/tmp/conclave-agent-test');
    expect(Platform.operatingSystem, isNotEmpty);
  });
}
