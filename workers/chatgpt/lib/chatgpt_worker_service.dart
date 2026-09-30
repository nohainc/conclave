import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conclave_cli_worker_runtime/conclave_cli_worker_runtime.dart';
import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';

const _safeMessages = <String, String>{
  WorkerIssueCode.providerToolUnavailable:
      'The required provider tool could not be found.',
  WorkerIssueCode.providerAuthenticationRequired:
      'Sign in to the configured provider on this computer.',
  WorkerIssueCode.deadlineExceeded: 'The assignment exceeded its time limit.',
  WorkerIssueCode.cancelled: 'The assignment was cancelled.',
  WorkerIssueCode.permissionDenied:
      'A local permission required for this assignment was denied.',
  WorkerIssueCode.providerFailure:
      'The provider could not complete the request.',
};

class ChatGptWorkerService {
  ChatGptWorkerService({
    Map<String, String>? environment,
    Directory? stateDirectory,
    CliExecutableLocator locator = const CliExecutableLocator(),
    CliCommandRunner commands = const CliCommandRunner(maxOutputBytes: 16384),
    CliStreamingRunner streams = const CliStreamingRunner(),
  }) : _sourceEnvironment = environment ?? Platform.environment,
       _stateDirectory =
           stateDirectory ??
           Directory(
             (environment ??
                     Platform.environment)['CONCLAVE_WORKER_STATE_DIR'] ??
                 Directory.current.path,
           ),
       _locator = locator,
       _commands = commands,
       _streams = streams;

  final Map<String, String> _sourceEnvironment;
  final Directory _stateDirectory;
  final CliExecutableLocator _locator;
  final CliCommandRunner _commands;
  final CliStreamingRunner _streams;
  String? _toolPath;
  String? _toolVersion;
  String? _lastObservedSessionId;

  Future<ProbeResult> probe(ProbeRequest request) async {
    final checks = <ProbeCheck>[];
    ProviderToolInfo? tool;
    String? issue;
    String? diagnostics;
    try {
      final info = await _resolveAndVerify();
      tool = ProviderToolInfo(
        name: 'Codex CLI',
        version: info.version,
        path: info.path,
      );
      checks.add(
        _check('provider_tool_discovery', 'Provider tool is installed.'),
      );
      checks.add(
        _check('provider_tool_version', 'Provider tool version was detected.'),
      );
      final login = await _commands.run(
        info.path,
        const ['login', 'status'],
        environment: _providerEnvironment(),
        workingDirectory: Directory.current.path,
        timeout: const Duration(seconds: 10),
      );
      if (login.exitCode == 0) {
        checks.add(_check('provider_authentication', 'Provider is signed in.'));
      } else {
        issue = WorkerIssueCode.providerAuthenticationRequired;
        checks.add(_failedCheck('provider_authentication', issue));
      }
      if (request.mode == WorkerProbeMode.live && issue == null) {
        try {
          final response = await _runPrompt(
            prompt: 'Reply with exactly the word OK. Do not use tools.',
            timeout: const Duration(seconds: 30),
            durable: false,
            expectedSessionId: null,
            model: null,
          );
          if (response.trim() == 'OK') {
            checks.add(
              _check(
                'provider_live_execution',
                'Provider completed a minimal live request.',
              ),
            );
          } else {
            issue = WorkerIssueCode.providerFailure;
            checks.add(_failedCheck('provider_live_execution', issue));
          }
        } on WorkerFailure catch (failure) {
          issue = failure.code;
          diagnostics = failure.diagnostics;
          checks.add(_failedCheck('provider_live_execution', issue));
        }
      } else if (request.mode == WorkerProbeMode.live) {
        checks.add(
          ProbeCheck(
            code: 'provider_live_execution',
            status: ProbeCheckStatus.warning,
            message: 'Live check was skipped because passive readiness failed.',
          ),
        );
      }
    } on WorkerFailure catch (failure) {
      issue = failure.code;
      diagnostics = failure.diagnostics;
      checks.add(_failedCheck(failure.code, failure.code));
    } on Object {
      issue = WorkerIssueCode.providerToolUnavailable;
      checks.add(_failedCheck(issue, issue));
    }
    return ProbeResult(
      requestId: request.requestId,
      mode: request.mode,
      ready: issue == null,
      tool: tool,
      checks: checks,
      issueCode: issue,
      diagnostics: diagnostics,
    );
  }

  Future<String> execute(
    ExecuteRequest request,
    WorkerExecutionContext context,
  ) async {
    final durable = request.sessionPolicy == WorkerSessionPolicy.durableSession;
    final sessionStore = WorkerSessionStore(_stateDirectory);
    final priorSession = durable
        ? await sessionStore.read(request.sessionKey!)
        : null;
    _lastObservedSessionId = null;
    final output = await _runPrompt(
      prompt: request.prompt,
      model: request.model,
      timeout: Duration(milliseconds: request.timeoutMs),
      expectedSessionId: priorSession,
      durable: durable,
      onProgress: (event) async {
        if (event == 'turn.started') {
          await context.reportProgress(
            10,
            message: 'Provider is working on the assignment.',
          );
        } else if (event == 'provider_tool.started') {
          await context.reportProgress(
            45,
            message: 'Provider is executing work in the Workstream.',
          );
        }
      },
    );
    if (durable) {
      final observed = _lastObservedSessionId;
      if (observed == null ||
          (priorSession != null && observed != priorSession)) {
        throw _failure(
          WorkerIssueCode.providerFailure,
          'Provider session could not be verified.',
        );
      }
      await sessionStore.write(request.sessionKey!, observed);
    }
    return output;
  }

  Future<String> _runPrompt({
    required String prompt,
    required Duration timeout,
    required bool durable,
    required String? expectedSessionId,
    required String? model,
    Future<void> Function(String event)? onProgress,
  }) async {
    final info = await _resolveAndVerify();
    final args = <String>[
      '--ask-for-approval',
      'never',
      '--sandbox',
      'workspace-write',
      'exec',
      '--json',
      '--color',
      'never',
      '--skip-git-repo-check',
      '--cd',
      Directory.current.absolute.path,
      if (model != null) ...['--model', model],
      if (expectedSessionId != null) ...[
        'resume',
        expectedSessionId,
      ] else if (!durable)
        '--ephemeral',
      '-',
    ];
    String? finalMessage;
    String? observedSessionId;
    String? providerError;
    var turnCompleted = false;
    final shortened = timeout - const Duration(seconds: 2);
    try {
      final result = await _streams.run(
        info.path,
        args,
        environment: _providerEnvironment(),
        workingDirectory: Directory.current.absolute.path,
        stdinText: prompt,
        timeout: shortened > Duration.zero
            ? shortened
            : const Duration(milliseconds: 250),
        onStdoutLine: (line) async {
          final Object? decoded;
          try {
            decoded = jsonDecode(line);
          } on FormatException {
            throw _failure(
              WorkerIssueCode.providerFailure,
              'Provider emitted an invalid event stream.',
            );
          }
          if (decoded is! Map) return;
          final event = Map<String, Object?>.from(decoded);
          final type = event['type'];
          if (type == 'thread.started') {
            final id = event['thread_id'];
            if (id is String && id.trim().isNotEmpty && id.length <= 256) {
              if (observedSessionId != null && observedSessionId != id) {
                throw _failure(
                  WorkerIssueCode.providerFailure,
                  'Provider session identity changed during execution.',
                );
              }
              observedSessionId = id;
              _lastObservedSessionId = id;
              if (expectedSessionId != null && id != expectedSessionId) {
                throw _failure(
                  WorkerIssueCode.providerFailure,
                  'Provider did not resume the expected session.',
                );
              }
            } else if (durable) {
              throw _failure(
                WorkerIssueCode.providerFailure,
                'Provider did not report a valid session identity.',
              );
            }
          } else if (type == 'turn.started') {
            await onProgress?.call('turn.started');
          } else if (type == 'item.completed') {
            final item = event['item'];
            if (item is Map &&
                item['type'] == 'agent_message' &&
                item['text'] is String) {
              final bytes = utf8.encode(item['text'] as String);
              final capped = bytes.length <= 512 * 1024
                  ? item['text'] as String
                  : utf8.decode(
                      bytes.take(512 * 1024).toList(),
                      allowMalformed: true,
                    );
              finalMessage = capped;
            }
          }
          if (const {
            'item.started',
            'item.updated',
            'item.completed',
          }.contains(type)) {
            final item = event['item'];
            if (item is Map &&
                const {
                  'command_execution',
                  'mcp_tool_call',
                  'web_search_call',
                }.contains(item['type'])) {
              await onProgress?.call('provider_tool.started');
            }
          }
          if (type == 'turn.completed') turnCompleted = true;
          if (type == 'turn.failed' || type == 'error') {
            final error = event['error'];
            providerError =
                (event['message'] ?? (error is Map ? error['message'] : null))
                    ?.toString() ??
                '';
          }
        },
      );
      if (providerError != null ||
          result.exitCode != 0 ||
          !turnCompleted ||
          finalMessage == null ||
          finalMessage!.isEmpty) {
        final code = _classify(providerError ?? result.stderr);
        throw _failure(
          code,
          _safeMessages[code]!,
          diagnostics: _safeDiagnostic(providerError ?? result.stderr),
        );
      }
      if (durable &&
          (observedSessionId == null ||
              (expectedSessionId != null &&
                  observedSessionId != expectedSessionId))) {
        throw _failure(
          WorkerIssueCode.providerFailure,
          'Provider session could not be verified.',
        );
      }
      return finalMessage!;
    } on TimeoutException {
      throw _failure(
        WorkerIssueCode.deadlineExceeded,
        _safeMessages[WorkerIssueCode.deadlineExceeded]!,
      );
    } on WorkerFailure {
      rethrow;
    } on ProcessException {
      throw _failure(
        WorkerIssueCode.providerToolUnavailable,
        _safeMessages[WorkerIssueCode.providerToolUnavailable]!,
      );
    } on Object {
      throw _failure(
        WorkerIssueCode.providerFailure,
        _safeMessages[WorkerIssueCode.providerFailure]!,
      );
    }
  }

  Future<({String path, String version})> _resolveAndVerify() async {
    if (_toolPath != null && _toolVersion != null) {
      return (path: _toolPath!, version: _toolVersion!);
    }
    final environment = _providerEnvironment();
    await _stateDirectory.create(recursive: true);
    final cacheFile = File(
      '${_stateDirectory.path}${Platform.pathSeparator}provider-tool-path.json',
    );
    String? cachedPath;
    try {
      final value = jsonDecode(await cacheFile.readAsString());
      if (value is Map && value['path'] is String) {
        final candidate = value['path'] as String;
        if (File(candidate).isAbsolute) cachedPath = candidate;
      }
    } on Object {
      // A missing or invalid cache is treated like a cache miss.
    }
    final home = environment['HOME'] ?? environment['USERPROFILE'];
    final homePaths = home == null
        ? <String>[]
        : [
            '$home${Platform.pathSeparator}.local${Platform.pathSeparator}bin',
            '$home${Platform.pathSeparator}.npm-global${Platform.pathSeparator}bin',
            '$home${Platform.pathSeparator}.npm${Platform.pathSeparator}bin',
            '$home${Platform.pathSeparator}.volta${Platform.pathSeparator}bin',
            '$home${Platform.pathSeparator}.bun${Platform.pathSeparator}bin',
          ];
    final standardPaths = Platform.isMacOS
        ? ['/opt/homebrew/bin', '/usr/local/bin', '/usr/bin', '/bin']
        : Platform.isLinux
        ? ['/usr/local/bin', '/usr/bin', '/bin']
        : Platform.isWindows
        ? [r'C:\Program Files\nodejs', r'C:\Windows\System32']
        : <String>[];
    Future<({String? version, String? path})> verifyCandidate(
      String? candidate,
    ) async {
      if (candidate == null) return (path: null, version: null);
      try {
        final result = await _commands.run(
          candidate,
          const ['--version'],
          environment: environment,
          workingDirectory: _stateDirectory.path,
          timeout: const Duration(seconds: 10),
        );
        final version = result.exitCode == 0
            ? RegExp(
                r'\b(\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?)\b',
              ).firstMatch(result.stdout)?.group(1)
            : null;
        return (path: version == null ? null : candidate, version: version);
      } on Object {
        return (path: null, version: null);
      }
    }

    var path = await _locator.locate(
      'codex',
      environment: environment,
      cachedPath: cachedPath,
      additionalPaths: homePaths,
      standardPaths: standardPaths,
      pathEntryLimit: 32,
    );
    var verified = await verifyCandidate(path);
    if (verified.path == null && cachedPath != null) {
      path = await _locator.locate(
        'codex',
        environment: environment,
        additionalPaths: homePaths,
        standardPaths: standardPaths,
        pathEntryLimit: 32,
      );
      verified = await verifyCandidate(path);
    }
    if (verified.path == null || verified.version == null) {
      if (path == null) {
        throw _failure(
          WorkerIssueCode.providerToolUnavailable,
          _safeMessages[WorkerIssueCode.providerToolUnavailable]!,
        );
      }
      throw _failure(
        WorkerIssueCode.providerFailure,
        'The installed provider tool version could not be verified.',
      );
    }
    _toolPath = verified.path;
    _toolVersion = verified.version;
    await _stateDirectory.create(recursive: true);
    await cacheFile.writeAsString(
      jsonEncode({'path': verified.path, 'version': _toolVersion}),
    );
    return (path: verified.path!, version: _toolVersion!);
  }

  Map<String, String> _providerEnvironment() {
    const allowed = {
      'PATH',
      'HOME',
      'USERPROFILE',
      'TMP',
      'TEMP',
      'TMPDIR',
      'LANG',
      'LC_ALL',
      'SSL_CERT_FILE',
      'SSL_CERT_DIR',
      'CODEX_HOME',
      'OPENAI_API_KEY',
    };
    return {
      for (final key in allowed)
        if (_sourceEnvironment[key] != null) key: _sourceEnvironment[key]!,
    };
  }

  ProbeCheck _check(String code, String message) =>
      ProbeCheck(code: code, status: ProbeCheckStatus.passed, message: message);

  ProbeCheck _failedCheck(String code, String issue) => ProbeCheck(
    code: code,
    status: ProbeCheckStatus.failed,
    message:
        _safeMessages[issue] ?? _safeMessages[WorkerIssueCode.providerFailure]!,
  );

  String _classify(String value) {
    final text = value.toLowerCase();
    if (RegExp(r'cancelled|canceled|user interrupted').hasMatch(text)) {
      return WorkerIssueCode.cancelled;
    }
    if (RegExp(r'timeout|timed out|deadline exceeded').hasMatch(text)) {
      return WorkerIssueCode.deadlineExceeded;
    }
    if (RegExp(
      r'unauthori[sz]ed|authentication required|not logged in|log in|sign in|token expired|invalid api key',
    ).hasMatch(text)) {
      return WorkerIssueCode.providerAuthenticationRequired;
    }
    if (RegExp(
      r'permission denied|approval denied|tool.*(denied|rejected)|sandbox.*(denied|blocked)',
    ).hasMatch(text)) {
      return WorkerIssueCode.permissionDenied;
    }
    return WorkerIssueCode.providerFailure;
  }

  String _safeDiagnostic(String value) {
    final code = _classify(value);
    return 'Provider process failure classified as $code.';
  }

  WorkerFailure _failure(String code, String message, {String? diagnostics}) =>
      WorkerFailure(
        code: code,
        message: message,
        retryable:
            code == WorkerIssueCode.deadlineExceeded ||
            code == WorkerIssueCode.providerFailure,
        diagnostics: diagnostics,
      );
}
