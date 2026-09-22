import 'dart:convert';
import 'dart:io';

import 'package:conclave_host/host.dart';
import 'package:test/test.dart';

void main() {
  test('writes structured logs to a user-private rotating log file', () async {
    final directory = await Directory.systemTemp.createTemp('conclave-logs-');
    final current = File('${directory.path}/logs/host-engine.log');
    await current.parent.create(recursive: true);
    await current.writeAsString('${List.filled(128, 'x').join()}\n');

    final engine = Host(
      config: HostConfig(dataDirectory: directory),
      logFileMaxBytes: 32,
    );
    await engine.start();
    await engine.stop();

    final rotated = File('${directory.path}/logs/host-engine.log.1');
    expect(await rotated.exists(), isTrue);
    final lines =
        (await current.readAsLines()).where((line) => line.isNotEmpty);
    expect(lines, isNotEmpty);
    expect(jsonDecode(lines.first), containsPair('level', 'info'));
    if (!Platform.isWindows) {
      expect((await current.stat()).mode & 0x1ff, 0x180);
      expect((await current.parent.stat()).mode & 0x1ff, 0x1c0);
    }
    await directory.delete(recursive: true);
  });
}
