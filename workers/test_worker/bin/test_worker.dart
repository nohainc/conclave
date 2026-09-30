import 'dart:async';
import 'dart:io';

import 'package:conclave_cli_worker_runtime/conclave_cli_worker_runtime.dart';
import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';

const workerTypeId = 'test';
const workerVersion = String.fromEnvironment(
  'WORKER_VERSION',
  defaultValue: '0.1.0',
);
const crashOnStart = bool.fromEnvironment('CRASH_ON_START');
const failPassiveProbe = bool.fromEnvironment('FAIL_PASSIVE_PROBE');

Future<void> main() async {
  if (crashOnStart) exit(23);

  final statePath = Platform.environment['CONCLAVE_WORKER_STATE_DIR'];
  final store = statePath == null
      ? null
      : WorkerSessionStore(Directory(statePath));
  final logger = const WorkerLogger();
  logger.log(
    'info',
    'worker.started',
    context: {
      'protocolStage': 'initialize',
      'workerTypeId': workerTypeId,
      'workerVersion': workerVersion,
    },
  );

  await WorkerRuntime(
    identity: const WorkerIdentity(
      workerTypeId: workerTypeId,
      workerVersion: workerVersion,
      capabilities: [
        'initialize',
        'probe',
        'execute',
        'progress',
        'durable_session',
      ],
    ),
    onProbe: (request) {
      if (failPassiveProbe && request.mode == WorkerProbeMode.passive) {
        return ProbeResult(
          requestId: request.requestId,
          mode: request.mode,
          ready: false,
          checks: [
            ProbeCheck(
              code: 'reference_worker_unready',
              status: ProbeCheckStatus.failed,
              message: 'Reference Worker passive probe failed',
            ),
          ],
          issueCode: WorkerIssueCode.providerToolUnavailable,
          diagnostics: 'Reference Worker passive probe failed',
        );
      }
      return ProbeResult(
        requestId: request.requestId,
        mode: request.mode,
        ready: true,
        tool: ProviderToolInfo(
          name: 'fake-provider',
          version: '1.0.0',
          path: Platform.resolvedExecutable,
        ),
        checks: [
          ProbeCheck(
            code: 'reference_worker_ready',
            status: ProbeCheckStatus.passed,
            message: request.mode == WorkerProbeMode.passive
                ? 'Passive local checks passed; no provider model request was made'
                : 'Live reference check passed without an external provider',
          ),
        ],
      );
    },
    onExecute: (request, context) async {
      logger.log(
        'info',
        'assignment.started',
        context: {
          'protocolStage': 'execute',
          'assignmentId': request.assignmentId,
          'sessionPolicy': request.sessionPolicy.name,
        },
      );
      final crash = RegExp(r'^crash=(\d+);').firstMatch(request.prompt);
      if (crash != null) exit(int.parse(crash.group(1)!));
      await context.reportProgress(0, message: 'Starting reference assignment');

      final parsed = _parseDelay(request.prompt);
      if (parsed.delay > Duration.zero)
        await Future<void>.delayed(parsed.delay);
      await context.reportProgress(
        50,
        message: 'Preparing deterministic result',
      );

      String? prior;
      if (request.sessionPolicy == WorkerSessionPolicy.durableSession) {
        if (store == null) {
          throw StateError(
            'durable session requested without a local state directory',
          );
        }
        final key = request.sessionKey!;
        prior = await store.read(key);
        final count = prior == null ? 1 : (int.tryParse(prior) ?? 0) + 1;
        await store.write(key, '$count');
      }

      await context.reportProgress(
        100,
        message: 'Reference assignment complete',
      );
      final content = parsed.text;
      return prior == null &&
              request.sessionPolicy == WorkerSessionPolicy.stateless
          ? 'echo: $content'
          : 'echo: $content (session run ${(int.tryParse(prior ?? '') ?? 0) + 1})';
    },
    logger: logger,
  ).run();
}

({Duration delay, String text}) _parseDelay(String prompt) {
  final match = RegExp(r'^delay=(\d+);(.*)$', dotAll: true).firstMatch(prompt);
  if (match == null) return (delay: Duration.zero, text: prompt);
  final milliseconds = int.parse(match.group(1)!);
  if (milliseconds > 120000) {
    throw const FormatException('reference delay exceeds two minutes');
  }
  return (delay: Duration(milliseconds: milliseconds), text: match.group(2)!);
}
