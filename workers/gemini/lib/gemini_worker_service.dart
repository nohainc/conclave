import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

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

class GeminiWorkerService {
  GeminiWorkerService({
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
  String? _lastObservedConversationId;

  Future<ProbeResult> probe(ProbeRequest request) async {
    final checks = <ProbeCheck>[];
    ProviderToolInfo? tool;
    String? issue;
    String? diagnostics;
    try {
      final info = await _resolveAndVerify();
      tool = ProviderToolInfo(
        name: 'Antigravity CLI',
        version: info.version,
        path: info.path,
      );
      checks.add(
        _check('provider_tool_discovery', 'Provider tool is installed.'),
      );
      checks.add(
        _check('provider_tool_version', 'Provider tool version was detected.'),
      );
      final configResult = await _inspectLocalConfiguration();
      checks.addAll(configResult.checks);
      issue = configResult.issueCode;

      if (request.mode == WorkerProbeMode.live && issue == null) {
        try {
          final response = await _runPrompt(
            prompt: 'Reply with exactly the word OK. Do not use tools.',
            timeout: const Duration(seconds: 30),
            durable: false,
            expectedConversationId: null,
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
            message:
                'Live check was skipped because local configuration failed.',
          ),
        );
      }
    } on WorkerFailure catch (failure) {
      issue = failure.code;
      diagnostics = failure.diagnostics;
      checks.add(_failedCheck(failure.code, failure.code));
    } on Object {
      issue = WorkerIssueCode.providerFailure;
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
    final priorConversationId = durable
        ? await sessionStore.read(request.sessionKey!)
        : null;
    _lastObservedConversationId = null;
    final output = await _runPrompt(
      prompt: request.prompt,
      model: request.model,
      timeout: Duration(milliseconds: request.timeoutMs),
      expectedConversationId: priorConversationId,
      durable: durable,
      onProgress: (stepType) async {
        await context.reportProgress(
          40,
          message: stepType == 'agent_response'
              ? 'Provider is preparing a response.'
              : 'Provider is working in the Workstream.',
        );
      },
    );
    if (durable) {
      final observed = _lastObservedConversationId;
      if (observed == null ||
          (priorConversationId != null && observed != priorConversationId)) {
        throw _failure(
          WorkerIssueCode.providerFailure,
          'Provider conversation could not be verified.',
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
    required String? expectedConversationId,
    required String? model,
    Future<void> Function(String stepType)? onProgress,
  }) async {
    final info = await _resolveAndVerify();
    final printTimeout = math.max(
      1,
      (timeout.inMilliseconds - 1500 + 999) ~/ 1000,
    );
    final args = <String>[
      '--input-format',
      'stream-json',
      '--output-format',
      'stream-json',
      '--sandbox',
      '--print-timeout',
      '${printTimeout}s',
      if (expectedConversationId != null) ...[
        '--conversation',
        expectedConversationId,
      ],
      if (model != null) ...['--model', model],
    ];
    String? finalResponse;
    String? observedConversationId;
    String? providerError;
    String? terminalStatus;
    var resultReceived = false;
    final input =
        '${jsonEncode({
          'event': 'user',
          'message': {'content': prompt},
        })}\n';
    final shortened = timeout - const Duration(milliseconds: 1800);
    try {
      final result = await _streams.run(
        info.path,
        args,
        environment: _providerEnvironment(),
        workingDirectory: Directory.current.absolute.path,
        stdinText: input,
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
          switch (event['event']) {
            case 'init':
              final id = event['conversation_id'];
              if (id is String && id.trim().isNotEmpty && id.length <= 256) {
                if (observedConversationId != null &&
                    observedConversationId != id) {
                  throw _failure(
                    WorkerIssueCode.providerFailure,
                    'Provider reported conflicting conversation identities.',
                  );
                }
                observedConversationId = id;
                _lastObservedConversationId = id;
                if (expectedConversationId != null &&
                    expectedConversationId != id) {
                  throw _failure(
                    WorkerIssueCode.providerFailure,
                    'Provider did not resume the expected conversation.',
                  );
                }
              } else if (durable) {
                throw _failure(
                  WorkerIssueCode.providerFailure,
                  'Provider did not report a valid conversation identity.',
                );
              }
            case 'step_update':
              final update = event['step_update'];
              if (update is Map && update['state'] == 'ACTIVE') {
                final stepType = update['step_type'];
                if (stepType is String) await onProgress?.call(stepType);
              }
            case 'result':
              final payload = event['result'];
              if (payload is! Map) {
                throw _failure(
                  WorkerIssueCode.providerFailure,
                  'Provider returned an invalid terminal result.',
                );
              }
              resultReceived = true;
              terminalStatus = payload['status']?.toString();
              final conversationId = payload['conversation_id'];
              if (conversationId is String && conversationId.isNotEmpty) {
                if (observedConversationId != null &&
                    observedConversationId != conversationId) {
                  throw _failure(
                    WorkerIssueCode.providerFailure,
                    'Provider returned inconsistent conversation identities.',
                  );
                }
                observedConversationId = conversationId;
                _lastObservedConversationId = conversationId;
              }
              if (terminalStatus == 'SUCCESS') {
                final response = payload['response'];
                if (response is String) finalResponse = _boundText(response);
              } else {
                providerError =
                    payload['error']?.toString() ??
                    'Provider ended with status ${terminalStatus ?? 'ERROR'}.';
              }
          }
        },
      );
      if (providerError != null ||
          result.exitCode != 0 ||
          !resultReceived ||
          terminalStatus != 'SUCCESS' ||
          finalResponse == null ||
          finalResponse!.isEmpty) {
        final code = _classify(providerError ?? result.stderr);
        throw _failure(
          code,
          _safeMessages[code]!,
          diagnostics: _safeDiagnostic(providerError ?? result.stderr),
        );
      }
      if (durable &&
          (observedConversationId == null ||
              (expectedConversationId != null &&
                  observedConversationId != expectedConversationId))) {
        throw _failure(
          WorkerIssueCode.providerFailure,
          'Provider conversation could not be verified.',
        );
      }
      return finalResponse!;
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
    await _stateDirectory.create(recursive: true);
    final environment = _providerEnvironment();
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
            '$home${Platform.pathSeparator}.gemini${Platform.pathSeparator}antigravity-cli${Platform.pathSeparator}bin',
            '$home${Platform.pathSeparator}AppData${Platform.pathSeparator}Local${Platform.pathSeparator}agy${Platform.pathSeparator}bin',
          ];
    final standardPaths = Platform.isMacOS
        ? ['/opt/homebrew/bin', '/usr/local/bin', '/usr/bin', '/bin']
        : Platform.isLinux
        ? ['/usr/local/bin', '/usr/bin', '/bin']
        : Platform.isWindows
        ? [
            '${environment['ProgramFiles'] ?? r'C:\Program Files'}${Platform.pathSeparator}Google${Platform.pathSeparator}antigravity-cli',
            r'C:\Windows\System32',
          ]
        : <String>[];

    Future<({String? path, String? version})> verify(String? candidate) async {
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
      'agy',
      environment: environment,
      cachedPath: cachedPath,
      additionalPaths: homePaths,
      standardPaths: standardPaths,
      pathEntryLimit: 32,
    );
    var verified = await verify(path);
    if (verified.path == null && cachedPath != null) {
      path = await _locator.locate(
        'agy',
        environment: environment,
        additionalPaths: homePaths,
        standardPaths: standardPaths,
        pathEntryLimit: 32,
      );
      verified = await verify(path);
    }
    if (verified.path == null || verified.version == null) {
      final absent = path == null;
      final code = absent
          ? WorkerIssueCode.providerToolUnavailable
          : WorkerIssueCode.providerFailure;
      throw _failure(
        code,
        absent
            ? _safeMessages[code]!
            : 'The installed provider tool version could not be verified.',
      );
    }
    _toolPath = verified.path;
    _toolVersion = verified.version;
    await cacheFile.writeAsString(
      jsonEncode({'path': verified.path, 'version': verified.version}),
    );
    return (path: verified.path!, version: verified.version!);
  }

  Future<({List<ProbeCheck> checks, String? issueCode})>
  _inspectLocalConfiguration() async {
    final environment = _providerEnvironment();
    final home = environment['HOME'] ?? environment['USERPROFILE'];
    if (home == null) {
      return (
        checks: [
          ProbeCheck(
            code: 'provider_configuration',
            status: ProbeCheckStatus.warning,
            message: 'The provider home directory is not available to inspect.',
          ),
        ],
        issueCode: null,
      );
    }
    final settingsFile = File(
      '$home${Platform.pathSeparator}.gemini${Platform.pathSeparator}antigravity-cli${Platform.pathSeparator}settings.json',
    );
    if (!await settingsFile.exists()) {
      return (
        checks: [
          ProbeCheck(
            code: 'provider_configuration',
            status: ProbeCheckStatus.warning,
            message:
                'No custom provider settings were found; local account login is checked by a live probe.',
          ),
        ],
        issueCode: null,
      );
    }
    try {
      final value = jsonDecode(await settingsFile.readAsString());
      if (value is! Map)
        throw const FormatException('settings must be an object');
      final modelProvider = value['modelProvider'];
      if (modelProvider != null && modelProvider != 'gemini') {
        return (
          checks: [
            ProbeCheck(
              code: 'provider_configuration',
              status: ProbeCheckStatus.failed,
              message: 'The local provider configuration is not supported.',
            ),
          ],
          issueCode: WorkerIssueCode.providerFailure,
        );
      }
      if (modelProvider == 'gemini' &&
          (environment['GEMINI_API_KEY']?.isNotEmpty != true)) {
        return (
          checks: [
            ProbeCheck(
              code: 'provider_authentication',
              status: ProbeCheckStatus.failed,
              message:
                  _safeMessages[WorkerIssueCode
                      .providerAuthenticationRequired]!,
            ),
          ],
          issueCode: WorkerIssueCode.providerAuthenticationRequired,
        );
      }
      return (
        checks: [
          _check(
            'provider_configuration',
            'Local provider settings are readable.',
          ),
          ProbeCheck(
            code: 'provider_authentication',
            status: ProbeCheckStatus.warning,
            message:
                'Provider account availability is checked by a live probe.',
          ),
        ],
        issueCode: null,
      );
    } on Object {
      return (
        checks: [
          ProbeCheck(
            code: 'provider_configuration',
            status: ProbeCheckStatus.failed,
            message: 'Local provider settings could not be read.',
          ),
        ],
        issueCode: WorkerIssueCode.providerFailure,
      );
    }
  }

  Map<String, String> _providerEnvironment() {
    const allowed = {
      'PATH',
      'HOME',
      'USERPROFILE',
      'ProgramFiles',
      'TMP',
      'TEMP',
      'TMPDIR',
      'LANG',
      'LC_ALL',
      'SSL_CERT_FILE',
      'SSL_CERT_DIR',
      'AGY_ADC_AUTH',
      'GEMINI_API_KEY',
      'GOOGLE_API_KEY',
      'GOOGLE_APPLICATION_CREDENTIALS',
      'GOOGLE_CLOUD_PROJECT',
      'GOOGLE_CLOUD_LOCATION',
      'GOOGLE_GEMINI_BASE_URL',
    };
    return {
      for (final key in allowed)
        if (_sourceEnvironment[key] != null) key: _sourceEnvironment[key]!,
    };
  }

  String _boundText(String value) {
    final bytes = utf8.encode(value);
    return bytes.length <= 512 * 1024
        ? value
        : utf8.decode(bytes.take(512 * 1024).toList(), allowMalformed: true);
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
    final text = value.toLowerCase().replaceAll('_', ' ');
    if (RegExp(
      r'cancelled|canceled|interrupted|user interrupted',
    ).hasMatch(text)) {
      return WorkerIssueCode.cancelled;
    }
    if (RegExp(r'timeout|timed out|deadline exceeded').hasMatch(text)) {
      return WorkerIssueCode.deadlineExceeded;
    }
    if (RegExp(
      r'enoent|executable not found|command not found',
    ).hasMatch(text)) {
      return WorkerIssueCode.providerToolUnavailable;
    }
    if (RegExp(
      r'unauthori[sz]ed|authentication required|not authenticated|sign in|login required|credentials? (missing|expired|invalid)|token expired|api key.{0,40}(not set|missing|invalid|revoked|expired)',
      caseSensitive: false,
    ).hasMatch(text)) {
      return WorkerIssueCode.providerAuthenticationRequired;
    }
    if (RegExp(
      r'permission denied|approval denied|permission.{0,60}(configuration|settings)|sandbox.*(denied|blocked)|tool.*(denied|rejected)',
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
