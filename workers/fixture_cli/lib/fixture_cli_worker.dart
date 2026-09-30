import 'dart:io';

import 'package:conclave_cli_worker_runtime/conclave_cli_worker_runtime.dart';
import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';

class FixtureCliWorker {
  FixtureCliWorker({
    CliExecutableLocator locator = const CliExecutableLocator(),
    CliCommandRunner commands = const CliCommandRunner(maxOutputBytes: 4096),
  }) : _locator = locator,
       _commands = commands;

  static const workerTypeId = 'fixture_cli';
  static const toolName = 'fixture-provider';

  final CliExecutableLocator _locator;
  final CliCommandRunner _commands;
  String? _toolPath;
  String? _toolVersion;

  WorkerRuntime createRuntime() => WorkerRuntime(
    identity: WorkerIdentity(
      workerTypeId: workerTypeId,
      workerVersion: const String.fromEnvironment(
        'WORKER_VERSION',
        defaultValue: '0.1.0',
      ),
      capabilities: const ['initialize', 'probe', 'execute'],
    ),
    onProbe: probe,
    onExecute: execute,
  );

  Future<ProbeResult> probe(ProbeRequest request) async {
    final path = await _resolveTool();
    final versionResult = await _commands.run(
      path,
      const ['--version'],
      environment: const {},
      workingDirectory: Directory.current.path,
      timeout: const Duration(seconds: 5),
    );
    if (versionResult.exitCode != 0) {
      return _unready(
        request,
        'fixture_cli_version',
        'Fixture CLI version check failed.',
      );
    }
    _toolVersion = _parseVersion(versionResult.stdout);
    if (_toolVersion == null) {
      return _unready(
        request,
        'fixture_cli_version',
        'Fixture CLI returned an invalid version.',
      );
    }

    final checks = <ProbeCheck>[
      ProbeCheck(
        code: 'fixture_cli_discovery',
        status: ProbeCheckStatus.passed,
        message: 'The Worker discovered its provider tool.',
      ),
      ProbeCheck(
        code: 'fixture_cli_version',
        status: ProbeCheckStatus.passed,
        message: 'The Worker detected its provider tool version.',
      ),
    ];
    if (request.mode == WorkerProbeMode.live) {
      final live = await _commands.run(
        path,
        const ['probe'],
        environment: const {},
        workingDirectory: Directory.current.path,
        timeout: const Duration(seconds: 5),
      );
      if (live.exitCode != 0 || live.stdout.trim() != 'ready') {
        return _unready(
          request,
          'fixture_cli_live_probe',
          'Fixture CLI live check failed.',
        );
      }
      checks.add(
        ProbeCheck(
          code: 'fixture_cli_live_probe',
          status: ProbeCheckStatus.passed,
          message: 'The local fixture CLI passed its live check.',
        ),
      );
    }
    return ProbeResult(
      requestId: request.requestId,
      mode: request.mode,
      ready: true,
      tool: ProviderToolInfo(name: toolName, version: _toolVersion, path: path),
      checks: checks,
    );
  }

  Future<String> execute(
    ExecuteRequest request,
    WorkerExecutionContext context,
  ) async {
    final path = await _resolveTool();
    await context.reportProgress(10, message: 'Starting fixture CLI');
    final result = await _commands.run(
      path,
      ['echo', request.prompt],
      environment: const {},
      workingDirectory: Directory.current.path,
      timeout: Duration(milliseconds: request.timeoutMs),
    );
    if (result.exitCode != 0) {
      throw WorkerFailure(
        code: WorkerIssueCode.providerFailure,
        message: 'The fixture provider tool failed.',
      );
    }
    await context.reportProgress(100, message: 'Fixture CLI completed');
    return result.stdout.trim();
  }

  Future<String> _resolveTool() async {
    final cached = _toolPath;
    if (cached != null) return cached;
    final executableDirectory = File(Platform.resolvedExecutable).parent.path;
    final path = await _locator.locate(
      toolName,
      environment: const {},
      additionalPaths: [executableDirectory],
      pathEntryLimit: 0,
    );
    if (path == null) {
      throw WorkerFailure(
        code: WorkerIssueCode.providerToolUnavailable,
        message: 'The fixture provider tool is unavailable.',
      );
    }
    _toolPath = path;
    return path;
  }

  ProbeResult _unready(
    ProbeRequest request,
    String checkCode,
    String message,
  ) => ProbeResult(
    requestId: request.requestId,
    mode: request.mode,
    ready: false,
    checks: [
      ProbeCheck(
        code: checkCode,
        status: ProbeCheckStatus.failed,
        message: message,
      ),
    ],
    issueCode: WorkerIssueCode.providerToolUnavailable,
    diagnostics: message,
  );

  String? _parseVersion(String text) {
    final match = RegExp(
      r'^fixture-provider (\d+\.\d+\.\d+)$',
    ).firstMatch(text.trim());
    return match?.group(1);
  }
}
