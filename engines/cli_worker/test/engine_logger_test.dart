import 'dart:convert';

import 'package:conclave_cli_worker_engine/src/engine_logger.dart';
import 'package:test/test.dart';

void main() {
  test('revision diagnostics expose logical scope without native state', () {
    final lines = <String>[];
    EngineLogger(writeLine: lines.add).log(
      'info',
      'engine.context.selected',
      context: {
        'conversationId': 'conversation',
        'workerSessionId': 'logical-session',
        'baseContextRevision': 104,
        'synchronizedContextRevision': 91,
        'targetContextRevision': 105,
        'synchronizedHistorySequence': 180,
        'throughSequence': 200,
        'nativeSessionId': 'private-provider-handle',
        'prompt': 'private context',
      },
    );
    final context = (jsonDecode(lines.single) as Map)['context'] as Map;
    expect(context['baseContextRevision'], 104);
    expect(context['synchronizedContextRevision'], 91);
    expect(context['targetContextRevision'], 105);
    expect(context['synchronizedHistorySequence'], 180);
    expect(context['throughSequence'], 200);
    expect(context['workerSessionId'], 'logical-session');
    expect(context.containsKey('nativeSessionId'), isFalse);
    expect(lines.single.contains('private'), isFalse);
  });

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
