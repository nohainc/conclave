import 'dart:convert';

import 'package:conclave_cli_worker_engine/src/engine_logger.dart';
import 'package:test/test.dart';

void main() {
  test('Engine logger redacts secrets and bounds diagnostic values', () {
    final lines = <String>[];
    EngineLogger(writeLine: lines.add).log(
      'info',
      'assignment.failed',
      context: {
        'assignmentId': 'assignment-1',
        'errorCode': 'authorization: super-secret-token',
        'prompt': 'private prompt text',
      },
    );
    final output = lines.single;
    final event = jsonDecode(output) as Map<String, dynamic>;
    expect(event['context']['errorCode'], contains('[REDACTED]'));
    expect(
      event['context']['errorCode'],
      isNot(contains('super-secret-token')),
    );
    expect(event['context'], isNot(contains('prompt')));

    lines.clear();
    EngineLogger(
      writeLine: lines.add,
    ).log('info', 'assignment.failed', context: {'errorCode': 'x' * 200});
    final bounded =
        (jsonDecode(lines.single)
                as Map<String, dynamic>)['context']['errorCode']
            as String;
    expect(bounded.length, 128);
  });
}
