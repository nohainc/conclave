import 'dart:convert';

import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';
import 'package:test/test.dart';

void main() {
  test(
    'rejects malformed JSON, unsupported frames, and wrong protocol versions',
    () {
      expect(() => decodeWorkerFrame('{'), throwsFormatException);
      expect(() => decodeWorkerFrame('[]'), throwsFormatException);
      expect(
        () => decodeWorkerFrame('{"type":"cancel.request","requestId":"1"}'),
        throwsFormatException,
      );
      expect(
        () => decodeWorkerFrame(
          '{"type":"probe.request","protocolVersion":"2.6","requestId":"1","mode":"passive"}',
        ),
        throwsFormatException,
      );
      expect(
        () => decodeWorkerFrame(
          '{"type":"initialize.request","protocolVersion":"4.0","requestId":"1","workerTypeId":"chatgpt","expectedEngineVersion":"1.0.0","profileDefinitionId":"chatgpt-codex","profileReleaseVersion":"1.0.0","profileDigest":"${'a' * 64}","providerSecret":"leak"}',
        ),
        throwsFormatException,
      );
      expect(
        () => decodeWorkerFrame(
          '{"type":"initialize.request","protocolVersion":"4.0","requestId":"1","workerTypeId":"chatgpt","expectedEngineVersion":"1.0.0","profileDefinitionId":"chatgpt-codex","profileReleaseVersion":"1.0.0","profileDigest":"not-a-digest"}',
        ),
        throwsFormatException,
      );
      expect(
        () => decodeWorkerFrame(
          '{"type":"initialize.request","protocolVersion":"4.0","requestId":"1","workerTypeId":"chatgpt","expectedEngineVersion":"1.0.0","profileDefinitionId":"chatgpt-codex","profileReleaseVersion":"1.0.0","profileDigest":"${'a' * 64}","expectedWorkerVersion":"1.0.0"}',
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'rejects credentials and local execution controls in Cloud assignment frames',
    () {
      for (final forbiddenKey in [
        'providerSecret',
        'providerSessionId',
        'executablePath',
        'cwd',
      ]) {
        expect(
          () => decodeWorkerFrame(
            '{"type":"execute.request","protocolVersion":"4.0","requestId":"1","assignmentId":"a","prompt":"p","model":null,"timeoutMs":1000,"sessionPolicy":"stateless","$forbiddenKey":"blocked"}',
          ),
          throwsFormatException,
          reason: 'must reject $forbiddenKey',
        );
      }
    },
  );

  test('validates probe mode and bounded probe data', () {
    expect(
      () => decodeWorkerFrame(
        '{"type":"probe.request","protocolVersion":"4.0","requestId":"1","mode":"quota_free"}',
      ),
      throwsFormatException,
    );
    expect(
      () => ProbeRequest(
        requestId: 'long-probe',
        mode: WorkerProbeMode.live,
        timeoutMs: WorkerProtocolLimits.maxProbeTimeoutMs + 1,
      ),
      throwsFormatException,
    );
    expect(
      () => decodeWorkerFrame(
        '{"type":"probe.request","protocolVersion":"4.0","requestId":"1","mode":"live","timeoutMs":30001}',
      ),
      throwsFormatException,
    );
    expect(
      () => ProbeResult(
        requestId: '1',
        mode: WorkerProbeMode.passive,
        ready: false,
        checks: List.generate(
          WorkerProtocolLimits.maxProbeChecks + 1,
          (index) => ProbeCheck(
            code: 'check_$index',
            status: ProbeCheckStatus.passed,
            message: 'ok',
          ),
        ),
        issueCode: WorkerIssueCode.providerToolUnavailable,
      ),
      throwsFormatException,
    );
    expect(
      () => decodeWorkerFrame(
        '{"type":"probe.result","requestId":"1","mode":"passive","ready":true,"providerToolName":"/usr/local/bin/codex","providerToolVersion":"1.0","checks":[],"issueCode":null,"diagnostics":null}',
      ),
      throwsFormatException,
      reason: 'probe metadata must not expose executable paths',
    );
    expect(
      () => decodeWorkerFrame(
        '{"type":"probe.result","requestId":"1","mode":"passive","ready":true,"providerToolName":"codex","providerToolVersion":"token=secret","checks":[],"issueCode":null,"diagnostics":null}',
      ),
      throwsFormatException,
      reason: 'provider version must be a safe token',
    );
  });

  test('requires a logical session key only for durable sessions', () {
    final stateless = <String, Object?>{
      'type': 'execute.request',
      'protocolVersion': '4.0',
      'requestId': '1',
      'assignmentId': 'a',
      'prompt': 'p',
      'model': null,
      'timeoutMs': 1000,
      'sessionPolicy': 'stateless',
    };
    expect(decodeWorkerFrame(jsonEncode(stateless)), isA<ExecuteRequest>());
    expect(
      () => decodeWorkerFrame(jsonEncode({...stateless, 'sessionKey': 'key'})),
      throwsFormatException,
    );
    expect(
      () => decodeWorkerFrame(
        jsonEncode({...stateless, 'sessionPolicy': 'durable_session'}),
      ),
      throwsFormatException,
    );
    expect(
      decodeWorkerFrame(
        jsonEncode({
          ...stateless,
          'sessionPolicy': 'durable_session',
          'sessionKey': 'opaque-conclave-key',
        }),
      ),
      isA<ExecuteRequest>(),
    );
  });

  test('enforces frame and prompt bounds', () {
    expect(
      () => decodeWorkerFrame(' ' * (WorkerProtocolLimits.maxFrameBytes + 1)),
      throwsFormatException,
    );
    expect(
      () => ExecuteRequest(
        requestId: '1',
        assignmentId: 'a',
        prompt: 'x' * (WorkerProtocolLimits.maxPromptBytes + 1),
        timeoutMs: 1000,
        sessionPolicy: WorkerSessionPolicy.stateless,
      ),
      throwsFormatException,
    );
    expect(
      () => ExecuteRequest(
        requestId: '1',
        assignmentId: 'a',
        prompt: '  ',
        timeoutMs: 1000,
        sessionPolicy: WorkerSessionPolicy.stateless,
      ),
      throwsFormatException,
    );
    expect(
      () => ExecuteRequest(
        requestId: '1',
        assignmentId: 'a',
        prompt: 'work',
        timeoutMs: 0,
        sessionPolicy: WorkerSessionPolicy.stateless,
      ),
      throwsFormatException,
    );
  });
}
