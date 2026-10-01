import 'dart:convert';
import 'dart:io';

import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';
import 'package:test/test.dart';

void main() {
  final fixtures = {
    'initialize.request.json': 'initialize.request',
    'initialize.result.json': 'initialize.result',
    'probe.passive.request.json': 'probe.request',
    'probe.live.request.json': 'probe.request',
    'probe.result.json': 'probe.result',
    'execute.request.json': 'execute.request',
    'progress.json': 'progress',
    'result.json': 'result',
    'error.json': 'error',
  };

  for (final entry in fixtures.entries) {
    test('matches golden ${entry.key}', () {
      final source = File(
        'test/fixtures/${entry.key}',
      ).readAsStringSync().trim();
      final frame = decodeWorkerFrame(source);
      expect(frame.type, entry.value);
      expect(jsonDecode(frame.encode()), jsonDecode(source));
    });
  }

  test(
    'initialize admission validates identity, state schema, and capabilities',
    () {
      final result = InitializeResult(
        requestId: 'init-1',
        workerTypeId: 'chatgpt',
        engineVersion: '1.4.2',
        profileDefinitionId: 'chatgpt-codex',
        profileReleaseVersion: '1.4.2',
        profileSchemaVersion: 1,
        capabilities: const ['execute', 'passive_probe'],
      );
      expect(
        () => validateInitializeAdmission(
          result,
          expectedWorkerTypeId: 'chatgpt',
          expectedEngineVersion: '1.4.2',
          expectedProfileDefinitionId: 'chatgpt-codex',
          expectedProfileReleaseVersion: '1.4.2',
          expectedProfileSchemaVersion: 1,
          requiredCapabilities: const {'execute', 'passive_probe'},
        ),
        returnsNormally,
      );
      expect(
        () => validateInitializeAdmission(
          result,
          expectedWorkerTypeId: 'gemini',
          expectedEngineVersion: '1.4.2',
          expectedProfileDefinitionId: 'chatgpt-codex',
          expectedProfileReleaseVersion: '1.4.2',
          expectedProfileSchemaVersion: 1,
          requiredCapabilities: const {'execute'},
        ),
        throwsFormatException,
      );
      expect(
        () => validateInitializeAdmission(
          result,
          expectedWorkerTypeId: 'chatgpt',
          expectedEngineVersion: '1.4.3',
          expectedProfileDefinitionId: 'chatgpt-codex',
          expectedProfileReleaseVersion: '1.4.2',
          expectedProfileSchemaVersion: 1,
          requiredCapabilities: const {'execute'},
        ),
        throwsFormatException,
      );
      expect(
        () => validateInitializeAdmission(
          result,
          expectedWorkerTypeId: 'chatgpt',
          expectedEngineVersion: '1.4.2',
          expectedProfileDefinitionId: 'chatgpt-codex',
          expectedProfileReleaseVersion: '1.4.2',
          expectedProfileSchemaVersion: 2,
          requiredCapabilities: const {'execute'},
        ),
        throwsFormatException,
      );
      expect(
        () => validateInitializeAdmission(
          result,
          expectedWorkerTypeId: 'chatgpt',
          expectedEngineVersion: '1.4.2',
          expectedProfileDefinitionId: 'chatgpt-codex',
          expectedProfileReleaseVersion: '1.4.2',
          expectedProfileSchemaVersion: 1,
          requiredCapabilities: const {'execute', 'live_probe'},
        ),
        throwsFormatException,
      );
      expect(
        () => validateInitializeAdmission(
          result,
          expectedWorkerTypeId: 'chatgpt',
          expectedEngineVersion: '1.4.2',
          expectedProfileDefinitionId: 'chatgpt-codex',
          expectedProfileReleaseVersion: '1.4.2',
          expectedProfileSchemaVersion: 1,
          requiredCapabilities: const {'execute'},
          negotiatedProtocolVersion: '2.6',
        ),
        throwsFormatException,
      );
    },
  );

  test('probe diagnostics redact credential-like values and stay bounded', () {
    final frame = ProbeResult(
      requestId: 'probe-1',
      mode: WorkerProbeMode.passive,
      ready: false,
      checks: const [],
      issueCode: WorkerIssueCode.providerAuthenticationRequired,
      diagnostics: '{"access_token":"hidden value"}',
    );
    expect(frame.diagnostics, contains('[REDACTED]'));
    expect(frame.diagnostics, isNot(contains('hidden value')));
  });
}
