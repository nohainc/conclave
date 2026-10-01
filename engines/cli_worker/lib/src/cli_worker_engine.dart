import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conclave_cli_worker_runtime/src/cli_command_runner.dart';
import 'package:conclave_cli_worker_runtime/src/cli_environment_builder.dart';
import 'package:conclave_cli_worker_runtime/src/cli_executable_locator.dart';
import 'package:conclave_cli_worker_runtime/src/cli_streaming_runner.dart';
import 'package:conclave_cli_worker_runtime/src/worker_process_cleanup.dart';
import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';
import 'package:conclave_tool_profile_v1/tool_profile_v1.dart';

import 'engine_logger.dart';
import 'engine_session_store.dart';

const _liveProbePrompt = 'Reply with exactly the word OK. Do not use tools.';
const _liveProbeExpectedText = 'OK';
const _compiledEngineVersion = String.fromEnvironment(
  'ENGINE_VERSION',
  defaultValue: 'dev',
);

class EngineOptions {
  EngineOptions({
    required this.profilePath,
    required this.engineVersion,
    required this.statePath,
  });

  final String profilePath;
  final String engineVersion;
  final String statePath;

  static EngineOptions parse(List<String> arguments) {
    final values = <String, String>{};
    for (var index = 0; index < arguments.length; index++) {
      final key = arguments[index];
      if (!const {
            '--profile',
            '--engine-version',
            '--state-directory',
          }.contains(key) ||
          values.containsKey(key) ||
          index + 1 >= arguments.length) {
        throw const FormatException(
          'expected --profile, --engine-version, and --state-directory options',
        );
      }
      values[key] = arguments[++index];
    }
    final profile = values['--profile'];
    final version = values['--engine-version'];
    final state = values['--state-directory'];
    if (profile == null ||
        version == null ||
        state == null ||
        !File(profile).isAbsolute ||
        !Directory(state).isAbsolute ||
        !_isSemver(version) ||
        (_compiledEngineVersion != 'dev' &&
            version != _compiledEngineVersion)) {
      throw const FormatException('Engine options are incomplete or invalid');
    }
    return EngineOptions(
      profilePath: profile,
      engineVersion: version,
      statePath: state,
    );
  }
}

/// Generic Protocol 4.0 process loop. Provider behavior comes from one admitted Profile.
class CliWorkerEngine {
  CliWorkerEngine({
    required this.options,
    CliExecutableLocator locator = const CliExecutableLocator(),
    CliCommandRunner commandRunner = const CliCommandRunner(
      maxOutputBytes: 64 * 1024,
    ),
    CliStreamingRunner? streamingRunner,
    EngineLogger logger = const EngineLogger(),
  }) : _locator = locator,
       _commandRunner = commandRunner,
       _streamingRunner =
           streamingRunner ??
           CliStreamingRunner(cleanup: const WorkerProcessCleanup()),
       _logger = logger;

  final EngineOptions options;
  final CliExecutableLocator _locator;
  final CliCommandRunner _commandRunner;
  final CliStreamingRunner _streamingRunner;
  final EngineLogger _logger;
  late final EngineProfile _profile;
  late final EngineSessionStore _sessions;
  String? _resolvedExecutable;
  String? _providerVersion;
  bool _initialized = false;
  final _operationStarts = <String, Stopwatch>{};

  Future<void> run({Stream<List<int>>? input, IOSink? output}) async {
    final profileFile = File(options.profilePath);
    final size = await profileFile.length();
    if (size < 1 || size > maxProfileBytes)
      throw const FormatException('Tool Profile payload is empty or oversized');
    final bytes = await profileFile.readAsBytes();
    _profile = EngineProfile.parse(bytes);
    if (!engineVersionCompatible(_profile, options.engineVersion)) {
      throw const FormatException(
        'Engine version is outside Profile compatibility',
      );
    }
    _sessions = EngineSessionStore(Directory(options.statePath));
    final lines = (input ?? stdin)
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    final sink = output ?? stdout;
    await for (final line in lines) {
      if (line.trim().isEmpty) continue;
      try {
        final frame = decodeWorkerFrame(line);
        switch (frame) {
          case InitializeRequest():
            await _initialize(frame, sink);
          case ProbeRequest():
            await _probe(frame, sink);
          case ExecuteRequest():
            await _execute(frame, sink);
          default:
            throw FormatException('unsupported request frame: ${frame.type}');
        }
      } on FormatException catch (error) {
        _logger.log(
          'warning',
          'engine.frame_rejected',
          context: {'errorCode': WorkerIssueCode.malformedFrame},
        );
        await _write(
          sink,
          WorkerErrorFrame(
            requestId: _requestIdFromLine(line),
            code: WorkerIssueCode.malformedFrame,
            message: error.message.length > 256
                ? 'Malformed protocol frame'
                : error.message,
          ),
        );
      } on Object {
        _logger.log(
          'error',
          'engine.request_failed',
          context: {'errorCode': WorkerIssueCode.workerInternalFailure},
        );
        await _write(
          sink,
          WorkerErrorFrame(
            requestId: _requestIdFromLine(line),
            code: WorkerIssueCode.workerInternalFailure,
            message: 'Engine request failed',
          ),
        );
      }
    }
  }

  Future<void> _initialize(InitializeRequest request, IOSink sink) async {
    if (request.workerTypeId != _profile.workerTypeId) {
      await _write(
        sink,
        WorkerErrorFrame(
          requestId: request.requestId,
          code: WorkerIssueCode.workerTypeMismatch,
          message: 'Logical Worker Type does not match the admitted Profile',
        ),
      );
      return;
    }
    if (request.expectedEngineVersion != options.engineVersion) {
      await _write(
        sink,
        WorkerErrorFrame(
          requestId: request.requestId,
          code: WorkerIssueCode.engineVersionMismatch,
          message: 'Engine version does not match Workspace admission',
        ),
      );
      return;
    }
    if (request.profileDefinitionId != _profile.definitionId ||
        request.profileReleaseVersion != _profile.releaseVersion.toString() ||
        request.profileDigest != _profile.digest) {
      await _write(
        sink,
        WorkerErrorFrame(
          requestId: request.requestId,
          code: WorkerIssueCode.profileIdentityMismatch,
          message: 'Engine Profile identity does not match Workspace admission',
        ),
      );
      return;
    }
    _initialized = true;
    _logger.log(
      'info',
      'engine.initialize.completed',
      context: _diagnosticContext(
        requestId: request.requestId,
        probeStage: 'initialize',
      ),
    );
    await _write(
      sink,
      InitializeResult(
        requestId: request.requestId,
        workerTypeId: _profile.workerTypeId,
        engineVersion: options.engineVersion,
        profileDefinitionId: _profile.definitionId,
        profileReleaseVersion: _profile.releaseVersion.toString(),
        profileSchemaVersion: _profile.schemaVersion,
        capabilities: _profile.capabilities,
      ),
    );
  }

  Future<void> _probe(ProbeRequest request, IOSink sink) async {
    if (!_initialized) return _write(sink, _notInitialized(request.requestId));
    final timer = Stopwatch()..start();
    _operationStarts[request.requestId] = timer;
    Duration remaining({int? profileLimitMs}) {
      final remainingMs = request.timeoutMs - timer.elapsedMilliseconds;
      if (remainingMs <= 0) {
        throw TimeoutException('Worker probe exceeded its deadline');
      }
      return Duration(
        milliseconds: profileLimitMs == null || remainingMs < profileLimitMs
            ? remainingMs
            : profileLimitMs,
      );
    }

    final checks = <ProbeCheck>[];
    String? issue;
    try {
      final executable = await _resolveTool();
      final versionProbe = _map(_profile.providerTool['versionProbe']);
      final discovery = _map(_profile.providerTool['discovery']);
      final env = _environment();
      final versionContext = _context(
        ExecuteRequest(
          requestId: request.requestId,
          assignmentId: 'version-probe',
          prompt: 'version probe',
          timeoutMs: _int(versionProbe['timeoutMs']),
          sessionPolicy: WorkerSessionPolicy.stateless,
        ),
        null,
      );
      final versionEnvironment = Map<String, String>.from(env);
      if (discovery['allowPathSearch'] != true) {
        versionEnvironment.remove('PATH');
      }
      final versionResult = await _commandRunner.run(
        executable,
        _stringList(
          versionProbe['arguments'],
        ).map((argument) => _template(argument, versionContext)).toList(),
        environment: versionEnvironment,
        workingDirectory: Directory.current.path,
        timeout: remaining(profileLimitMs: _int(versionProbe['timeoutMs'])),
      );
      final versionSource = versionProbe['source'] == 'stderr'
          ? versionResult.stderr
          : versionResult.stdout;
      final version = _extractSemver(versionSource);
      if (versionResult.exitCode != 0 || version == null) {
        throw const EngineProviderException(
          WorkerIssueCode.unsupportedProviderToolVersion,
          'Provider CLI version could not be verified',
        );
      }
      _providerVersion = version;
      if (!_supportedProviderVersion(version)) {
        issue = WorkerIssueCode.unsupportedProviderToolVersion;
        checks.add(
          ProbeCheck(
            code: 'provider_tool_version',
            status: ProbeCheckStatus.failed,
            message: 'Provider CLI version is not supported by this Profile.',
          ),
        );
      } else {
        checks.add(
          ProbeCheck(
            code: 'provider_tool_version',
            status: ProbeCheckStatus.passed,
            message: 'Provider CLI version is supported.',
          ),
        );
      }
      if (issue == null) {
        final passive = _map(_profile.probe['passive']);
        final commands = passive['checks'];
        if (commands is List) {
          for (final raw in commands) {
            final check = _map(raw);
            final result = await _commandRunner.run(
              executable,
              _stringList(
                check['arguments'],
              ).map((argument) => _template(argument, versionContext)).toList(),
              environment: env,
              workingDirectory: Directory.current.path,
              timeout: remaining(profileLimitMs: _int(check['timeoutMs'])),
            );
            final success = _intList(
              check['successExitCodes'],
            ).contains(result.exitCode);
            final id = _string(check['id']);
            checks.add(
              ProbeCheck(
                code: id.replaceAll('-', '_'),
                status: success
                    ? ProbeCheckStatus.passed
                    : ProbeCheckStatus.failed,
                message: success
                    ? 'Local provider check passed.'
                    : 'Local provider check failed.',
              ),
            );
            if (!success) issue ??= _string(check['failureIssueCode']);
          }
        }
        final configChecks = passive['configChecks'];
        if (configChecks is List) {
          for (final rawCheck in configChecks) {
            final outcome = await _runConfigCheck(_map(rawCheck));
            checks.add(outcome.check);
            if (outcome.issueCode != null) issue ??= outcome.issueCode;
          }
        }
        if (request.mode == WorkerProbeMode.live && issue == null) {
          final liveConfig = _profile.probe['live'];
          final profileTimeoutMs = liveConfig is Map
              ? _int(liveConfig['timeoutMs'])
              : WorkerProtocolLimits.maxProbeTimeoutMs;
          final liveTimeout = remaining(profileLimitMs: profileTimeoutMs);
          final liveContext = _context(
            ExecuteRequest(
              requestId: request.requestId,
              assignmentId: 'live-probe',
              prompt: _liveProbePrompt,
              timeoutMs: liveTimeout.inMilliseconds,
              sessionPolicy: WorkerSessionPolicy.stateless,
            ),
            null,
          );
          final liveStdout = StringBuffer();
          final liveResult = await _streamingRunner.run(
            executable,
            _expandArguments(
              _list(_profile.execution['arguments']),
              liveContext,
            ),
            environment: _environment(liveContext),
            workingDirectory: liveContext['workingDirectory']!,
            stdinText: _expandStdin(
              _map(_profile.execution['stdin']),
              liveContext,
            ),
            timeout: liveTimeout,
            onStdoutLine: (line) => liveStdout.writeln(line),
          );
          final liveOutput = _interpret(
            liveStdout.toString(),
            liveResult.stderr,
            liveResult.exitCode,
            _profile.execution,
          );
          final livePassed =
              liveResult.exitCode == 0 &&
              liveOutput.issueCode == null &&
              liveOutput.finalText?.trim() == _liveProbeExpectedText;
          checks.add(
            ProbeCheck(
              code: 'provider_live_execution',
              status: livePassed
                  ? ProbeCheckStatus.passed
                  : ProbeCheckStatus.failed,
              message: livePassed
                  ? 'Provider completed the live check.'
                  : 'Provider did not complete the expected live check.',
            ),
          );
          if (!livePassed)
            issue ??= liveOutput.issueCode ?? WorkerIssueCode.providerFailure;
        } else if (request.mode == WorkerProbeMode.live && issue != null) {
          checks.add(
            ProbeCheck(
              code: 'provider_live_execution',
              status: ProbeCheckStatus.warning,
              message:
                  'Live check was skipped because passive readiness failed.',
            ),
          );
        }
      }
    } on EngineProviderException catch (error) {
      issue = error.issueCode;
      checks.add(
        ProbeCheck(
          code: 'provider_tool',
          status: ProbeCheckStatus.failed,
          message: error.safeMessage,
        ),
      );
    } on ProcessException {
      issue = WorkerIssueCode.providerToolUnavailable;
      checks.add(
        ProbeCheck(
          code: 'provider_tool',
          status: ProbeCheckStatus.failed,
          message: 'Provider CLI could not be started.',
        ),
      );
    } on TimeoutException {
      issue = WorkerIssueCode.deadlineExceeded;
      checks.add(
        ProbeCheck(
          code: 'provider_tool',
          status: ProbeCheckStatus.failed,
          message: 'Provider CLI probe exceeded its deadline.',
        ),
      );
    } on Object {
      issue = WorkerIssueCode.providerFailure;
      checks.add(
        ProbeCheck(
          code: 'provider_tool',
          status: ProbeCheckStatus.failed,
          message: 'Provider CLI probe failed.',
        ),
      );
    }
    await _write(
      sink,
      ProbeResult(
        requestId: request.requestId,
        mode: request.mode,
        ready: issue == null,
        providerToolName: _string(_profile.providerTool['name']),
        providerToolVersion: _providerVersion,
        checks: checks,
        issueCode: issue,
      ),
    );
  }

  Future<_ProbeOutcome> _runConfigCheck(Map<String, Object?> spec) async {
    final id = _string(spec['id']).replaceAll('-', '_');
    final relative = _string(spec['relativePath']);
    if (spec['root'] != 'home' ||
        relative.startsWith('/') ||
        relative
            .split('/')
            .any((part) => part.isEmpty || part == '.' || part == '..') ||
        !RegExp(r'^[A-Za-z0-9._/-]+$').hasMatch(relative)) {
      throw const FormatException('unsafe Profile config check path');
    }
    final providerEnvironment = _environment();
    final home =
        providerEnvironment['HOME'] ?? providerEnvironment['USERPROFILE'];
    if (home == null || home.isEmpty) {
      return _configOutcome(
        id,
        _string(spec['onMissing']),
        WorkerIssueCode.providerFailure,
      );
    }
    final file = File(
      '$home${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}',
    );
    if (!await file.exists()) {
      return _configOutcome(
        id,
        _string(spec['onMissing']),
        WorkerIssueCode.providerFailure,
      );
    }
    final maxBytes = _int(spec['maxBytes']);
    if (maxBytes < 1 ||
        maxBytes > 64 * 1024 ||
        await file.length() > maxBytes) {
      return _configOutcome(
        id,
        _string(spec['onInvalid']),
        WorkerIssueCode.providerFailure,
      );
    }
    final homeRealPath = await Directory(home).resolveSymbolicLinks();
    final fileRealPath = await file.resolveSymbolicLinks();
    if (!fileRealPath.startsWith('$homeRealPath${Platform.pathSeparator}')) {
      throw const FormatException(
        'Profile config check escaped the home boundary',
      );
    }
    Object? decoded;
    try {
      decoded = jsonDecode(await file.readAsString());
    } on Object {
      return _configOutcome(
        id,
        _string(spec['onInvalid']),
        WorkerIssueCode.providerFailure,
      );
    }
    final rules = _list(spec['rules']);
    for (final raw in rules) {
      final rule = _map(raw);
      if (!_matches(decoded, rule['when'])) continue;
      final required = rule['requiredEnvironmentAny'];
      if (required is List &&
          !required.any(
            (key) => providerEnvironment[key]?.isNotEmpty == true,
          )) {
        final missing = rule['whenEnvironmentMissing'];
        if (missing is Map) {
          final missingMap = _map(missing);
          return _configOutcome(
            id,
            _string(missingMap['result']),
            missingMap['issueCode'] is String
                ? missingMap['issueCode'] as String
                : WorkerIssueCode.providerAuthenticationRequired,
          );
        }
      }
      return _configOutcome(
        id,
        _string(rule['result']),
        rule['issueCode'] is String
            ? rule['issueCode'] as String
            : WorkerIssueCode.providerAuthenticationRequired,
      );
    }
    final noMatch = _map(spec['onNoMatch']);
    return _configOutcome(
      id,
      _string(noMatch['result']),
      noMatch['issueCode'] is String
          ? noMatch['issueCode'] as String
          : WorkerIssueCode.providerAuthenticationRequired,
    );
  }

  _ProbeOutcome _configOutcome(String id, String status, String issue) {
    final parsed = switch (status) {
      'passed' => ProbeCheckStatus.passed,
      'warning' => ProbeCheckStatus.warning,
      'failed' => ProbeCheckStatus.failed,
      _ => throw const FormatException('invalid config check status'),
    };
    return _ProbeOutcome(
      ProbeCheck(
        code: id,
        status: parsed,
        message: parsed == ProbeCheckStatus.passed
            ? 'Local configuration check passed.'
            : parsed == ProbeCheckStatus.warning
            ? 'Local configuration needs attention.'
            : 'Local configuration check failed.',
      ),
      parsed == ProbeCheckStatus.failed ||
              (parsed == ProbeCheckStatus.warning &&
                  issue == WorkerIssueCode.providerAuthenticationRequired)
          ? issue
          : null,
    );
  }

  Future<void> _execute(ExecuteRequest request, IOSink sink) async {
    _operationStarts[request.requestId] = Stopwatch()..start();
    if (!_initialized)
      return _write(
        sink,
        _notInitialized(request.requestId, assignmentId: request.assignmentId),
      );
    final execution = _profile.execution;
    final sessionPolicy =
        request.sessionPolicy == WorkerSessionPolicy.durableSession
        ? 'durable'
        : 'stateless';
    final sessionProfile = _profile.session;
    if (request.model != null) {
      final model = _profile.model;
      final allowlist = model['allowlist'];
      if (model['supported'] != true ||
          (model['unknownModelPolicy'] == 'profile_allowlist' &&
              (allowlist is! List || !allowlist.contains(request.model)))) {
        return _write(
          sink,
          WorkerErrorFrame(
            requestId: request.requestId,
            assignmentId: request.assignmentId,
            code: WorkerIssueCode.modelNotSupported,
            message: 'Requested model is not supported by this Tool Profile',
          ),
        );
      }
    }
    if (sessionPolicy == 'durable' && sessionProfile['supported'] != true) {
      return _write(
        sink,
        WorkerErrorFrame(
          requestId: request.requestId,
          assignmentId: request.assignmentId,
          code: WorkerIssueCode.sessionResumeFailed,
          message: 'This Tool Profile does not support durable sessions',
        ),
      );
    }
    final providerTool = _profile.providerTool;
    final providerToolIdentity = _string(providerTool['name']);
    final compatibleSessionFormats = _list(
      sessionProfile['compatibleFormatIds'],
    ).cast<String>();
    final priorSession = request.sessionKey == null
        ? null
        : await _sessions.read(
            sessionKey: request.sessionKey!,
            workerTypeId: _profile.workerTypeId,
            profileDefinitionId: _profile.definitionId,
            providerToolIdentity: providerToolIdentity,
            compatibleFormatIds: compatibleSessionFormats,
          );
    final context = _context(request, priorSession);
    try {
      final executable = await _resolveTool();
      final args = _expandArguments(_list(execution['arguments']), context);
      final stdinText = _expandStdin(_map(execution['stdin']), context);
      final eventProgress = <String>{};
      final stdout = StringBuffer();
      var stdoutBytes = 0;
      final result = await _streamingRunner.run(
        executable,
        args,
        environment: _environment(context),
        workingDirectory: context['workingDirectory']!,
        stdinText: stdinText,
        timeout: Duration(milliseconds: request.timeoutMs),
        onStdoutLine: (line) async {
          stdoutBytes += utf8.encode(line).length + 1;
          if (stdoutBytes > 4 * 1024 * 1024) {
            throw const FormatException('provider output exceeds Engine limit');
          }
          stdout.writeln(line);
          for (final progress in _progressForLine(line, execution)) {
            final key = '${progress.$1}:${progress.$2}';
            if (eventProgress.add(key)) {
              await _write(
                sink,
                WorkerProgress(
                  requestId: request.requestId,
                  assignmentId: request.assignmentId,
                  percentage: progress.$1.toDouble(),
                  message: progress.$2,
                ),
              );
            }
          }
        },
      );
      final interpreted = _interpret(
        stdout.toString(),
        result.stderr,
        result.exitCode,
        execution,
        priorSession: priorSession,
        durable: request.sessionPolicy == WorkerSessionPolicy.durableSession,
      );
      if (interpreted.issueCode != null || result.exitCode != 0) {
        await _write(
          sink,
          WorkerErrorFrame(
            requestId: request.requestId,
            assignmentId: request.assignmentId,
            code: interpreted.issueCode ?? WorkerIssueCode.providerFailure,
            message: 'Provider CLI execution failed',
            diagnostics: result.stderr.isEmpty ? null : result.stderr,
          ),
        );
        return;
      }
      final sessionId = interpreted.sessionId;
      if (request.sessionPolicy == WorkerSessionPolicy.durableSession) {
        if (sessionId == null || sessionId.isEmpty) {
          await _write(
            sink,
            WorkerErrorFrame(
              requestId: request.requestId,
              assignmentId: request.assignmentId,
              code: WorkerIssueCode.providerFailure,
              message:
                  'Provider did not return the required durable session identity',
            ),
          );
          return;
        }
        await _sessions.write(
          sessionKey: request.sessionKey!,
          workerTypeId: _profile.workerTypeId,
          profileDefinitionId: _profile.definitionId,
          providerToolIdentity: providerToolIdentity,
          profileReleaseVersion: _profile.releaseVersion,
          sessionFormatId: _string(sessionProfile['formatId']),
          sessionId: sessionId,
        );
      }
      await _write(
        sink,
        WorkerResult(
          requestId: request.requestId,
          assignmentId: request.assignmentId,
          output: interpreted.finalText ?? '',
        ),
      );
    } on TimeoutException {
      await _write(
        sink,
        WorkerErrorFrame(
          requestId: request.requestId,
          assignmentId: request.assignmentId,
          code: WorkerIssueCode.deadlineExceeded,
          message: 'Provider CLI execution exceeded its deadline',
        ),
      );
    } on ProcessException {
      await _write(
        sink,
        WorkerErrorFrame(
          requestId: request.requestId,
          assignmentId: request.assignmentId,
          code: WorkerIssueCode.providerToolUnavailable,
          message: 'Provider CLI could not be started',
        ),
      );
    } on Object {
      await _write(
        sink,
        WorkerErrorFrame(
          requestId: request.requestId,
          assignmentId: request.assignmentId,
          code: WorkerIssueCode.providerFailure,
          message: 'Provider CLI execution failed',
        ),
      );
    }
  }

  Map<String, String> _context(ExecuteRequest request, String? sessionId) => {
    'prompt': request.prompt,
    'workingDirectory': Directory.current.path,
    'home': Platform.environment['HOME'] ?? Directory.current.path,
    'workerStateDirectory': options.statePath,
    'timeoutMs':
        '${(request.timeoutMs - _int(_profile.timeout['providerReserveMs'])).clamp(1, request.timeoutMs)}',
    'timeoutSeconds':
        '${((request.timeoutMs - _int(_profile.timeout['providerReserveMs'])).clamp(1, request.timeoutMs) / 1000).ceil()}',
    if (request.model != null) 'model': request.model!,
    if (sessionId != null) 'sessionId': sessionId,
    'executionPolicy': 'restricted',
    'sessionPolicy': request.sessionPolicy == WorkerSessionPolicy.durableSession
        ? 'durable'
        : 'stateless',
  };

  List<String> _expandArguments(
    List<Object?> source,
    Map<String, String> context,
  ) {
    final output = <String>[];
    final policy = context['executionPolicy']!;
    for (final part in source) {
      if (part is String) {
        output.add(_template(part, context));
      } else {
        final marker = _map(part);
        final keys = marker.keys.toSet();
        final knownMarker =
            (marker.length == 1 &&
                const {
                  'sandboxPolicyMapping',
                  'modelArguments',
                  'sessionResumeArguments',
                  'providerTimeoutArguments',
                }.contains(marker.keys.single)) ||
            (marker.length == 2 && keys.containsAll({'ifPresent', 'values'})) ||
            (marker.length == 3 &&
                keys.containsAll({'ifAbsent', 'ifSessionPolicy', 'values'}));
        if (!knownMarker) {
          throw const FormatException('unknown structured argument form');
        }
        if (marker['sandboxPolicyMapping'] == true) {
          output.addAll(
            _stringList(
              _map(_profile.sandbox['mappings'])[policy],
            ).map((v) => _template(v, context)),
          );
        } else if (marker['modelArguments'] == true &&
            context.containsKey('model')) {
          output.addAll(
            _stringList(
              _profile.model['arguments'],
            ).map((v) => _template(v, context)),
          );
        } else if (marker['sessionResumeArguments'] == true &&
            context.containsKey('sessionId')) {
          output.addAll(
            _stringList(
              _profile.session['resumeArguments'],
            ).map((v) => _template(v, context)),
          );
        } else if (marker['providerTimeoutArguments'] == true) {
          output.addAll(
            _stringList(
              _profile.timeout['providerArguments'],
            ).map((v) => _template(v, context)),
          );
        } else if (marker['ifPresent'] == 'model' &&
                context.containsKey('model') ||
            marker['ifPresent'] == 'sessionId' &&
                context.containsKey('sessionId')) {
          output.addAll(
            _stringList(marker['values']).map((v) => _template(v, context)),
          );
        } else if (marker['ifAbsent'] == 'sessionId' &&
            !context.containsKey('sessionId') &&
            marker['ifSessionPolicy'] == context['sessionPolicy']) {
          output.addAll(
            _stringList(marker['values']).map((v) => _template(v, context)),
          );
        }
      }
      if (output.length > 128)
        throw const FormatException('expanded arguments exceed Engine limit');
    }
    return output;
  }

  String _expandStdin(Map<String, Object?> spec, Map<String, String> context) {
    if (spec['mode'] == 'raw_text') {
      final value = _template(_string(spec['value']), context);
      if (utf8.encode(value).length > 1024 * 1024) {
        throw const FormatException('provider stdin exceeds Engine limit');
      }
      return value;
    }
    final value = _expandJson(spec['value'], context);
    final encoded =
        '${jsonEncode(value)}${spec['appendNewline'] == true ? '\n' : ''}';
    if (utf8.encode(encoded).length > 1024 * 1024) {
      throw const FormatException('provider stdin exceeds Engine limit');
    }
    return encoded;
  }

  Object? _expandJson(
    Object? value,
    Map<String, String> context, [
    int depth = 0,
  ]) {
    if (depth > 16)
      throw const FormatException('JSON stdin template exceeds depth limit');
    if (value is String) return _template(value, context);
    if (value is List) {
      if (value.length > 64)
        throw const FormatException('JSON stdin array exceeds limit');
      return value
          .map((item) => _expandJson(item, context, depth + 1))
          .toList();
    }
    if (value is Map) {
      if (value.length > 64)
        throw const FormatException('JSON stdin object exceeds limit');
      return value.map(
        (key, item) =>
            MapEntry(key.toString(), _expandJson(item, context, depth + 1)),
      );
    }
    return value;
  }

  String _template(String value, Map<String, String> context) {
    final placeholders = RegExp(r'\{\{([^{}]+)\}\}');
    final scrubbed = value.replaceAll(placeholders, '');
    if (RegExp(r'\{\{|\}\}').hasMatch(scrubbed)) {
      throw const FormatException('malformed Profile placeholder');
    }
    return value.replaceAllMapped(placeholders, (match) {
      final key = match.group(1)!;
      final result = context[key];
      if (result == null)
        throw FormatException('Profile placeholder is unavailable: $key');
      return result;
    });
  }

  Map<String, String> _environment([Map<String, String> context = const {}]) {
    final env = _map(_profile.environment);
    final passthrough = _stringList(env['passthrough']);
    final parent = <String, String>{
      for (final key in passthrough)
        if (Platform.environment[key] case final value?) key: value,
    };
    final sets = _map(env['set']);
    final values = <String, String>{
      for (final entry in sets.entries)
        entry.key: _template(
          entry.value.toString(),
          context.isEmpty
              ? {
                  'home':
                      Platform.environment['HOME'] ?? Directory.current.path,
                  'workingDirectory': Directory.current.path,
                  'workerStateDirectory': options.statePath,
                  'prompt': '',
                  'timeoutMs': '1',
                  'timeoutSeconds': '1',
                }
              : context,
        ),
    };
    final environment = CliEnvironmentBuilder(
      allowedParentKeys: passthrough.toSet(),
    ).build(values: values, parentEnvironment: parent);
    if (environment.length > 64 ||
        environment.entries.any(
          (entry) =>
              utf8.encode(entry.key).length > 128 ||
              utf8.encode(entry.value).length > 64 * 1024,
        ) ||
        environment.entries.fold<int>(
              0,
              (size, entry) =>
                  size +
                  utf8.encode(entry.key).length +
                  utf8.encode(entry.value).length,
            ) >
            256 * 1024) {
      throw const FormatException('Profile environment exceeds Engine limits');
    }
    return environment;
  }

  Future<String> _resolveTool() async {
    if (_resolvedExecutable != null) return _resolvedExecutable!;
    final tool = _profile.providerTool;
    final discovery = _map(tool['discovery']);
    final locations = _stringList(
      discovery['standardLocations'],
    ).map(_expandHomeLocation).toList();
    final candidates = _stringList(tool['executableCandidates']);
    final discoveryEnvironment = Map<String, String>.from(Platform.environment);
    if (discovery['allowPathSearch'] != true) {
      discoveryEnvironment.remove('PATH');
    }
    for (final candidate in candidates) {
      final path = await _locator.locate(
        candidate,
        environment: discoveryEnvironment,
        standardPaths: locations,
        cacheFile: File(
          '${options.statePath}${Platform.pathSeparator}'
          'provider-path-${_profile.definitionId}.json',
        ),
        cacheIdentity: '${_profile.definitionId}:$candidate',
      );
      if (path != null) return _resolvedExecutable = path;
    }
    throw const EngineProviderException(
      WorkerIssueCode.providerToolUnavailable,
      'Provider CLI was not found',
    );
  }

  String _expandHomeLocation(String location) {
    final home = Platform.isWindows
        ? Platform.environment['USERPROFILE'] ?? Platform.environment['HOME']
        : Platform.environment['HOME'];
    if (location == '{{home}}') return home ?? '';
    if (location.startsWith('{{home}}/'))
      return '${home ?? ''}/${location.substring(9)}';
    const allowed = {'/opt/homebrew/bin', '/usr/local/bin', '/usr/bin', '/bin'};
    if (!allowed.contains(location))
      throw const FormatException(
        'Profile discovery location is not Engine-approved',
      );
    return location;
  }

  bool _supportedProviderVersion(String version) {
    final ranges = _profile.providerTool['supportedVersions'];
    if (ranges is! List) return false;
    for (final raw in ranges) {
      final range = _map(raw);
      try {
        if (semanticVersionInRange(
          version,
          _string(range['min']),
          _string(range['maxExclusive']),
        )) {
          return true;
        }
      } on FormatException {
        continue;
      }
    }
    return false;
  }

  List<(int, String)> _progressForLine(
    String line,
    Map<String, Object?> execution,
  ) {
    final output = _map(execution['output']);
    if (output['mode'] != 'jsonl') return const [];
    Object? event;
    try {
      event = jsonDecode(line);
    } on Object {
      return const [];
    }
    if (event is! Map) return const [];
    final progress = _profile.json['progress'];
    if (progress is! List) return const [];
    final result = <(int, String)>[];
    for (final ruleRaw in _list(execution['events'])) {
      final rule = _map(ruleRaw);
      if (!_matches(event, rule['when'])) continue;
      for (final actionRaw in _list(rule['actions'])) {
        final action = _map(actionRaw);
        if (action['type'] == 'emit_progress') {
          result.add((
            _int(action['percentage']),
            _string(action['messageKey']),
          ));
        }
      }
    }
    for (final ruleRaw in progress) {
      final rule = _map(ruleRaw);
      if (_matches(event, rule['when']))
        result.add((_int(rule['percentage']), _string(rule['messageKey'])));
    }
    return result;
  }

  _InterpretedOutput _interpret(
    String stdout,
    String stderr,
    int exitCode,
    Map<String, Object?> execution, {
    String? priorSession,
    bool durable = false,
  }) {
    final mode = _string(_map(execution['output'])['mode']);
    if (mode == 'plain_text')
      return _InterpretedOutput(
        exitCode == 0 && stdout.trim().isNotEmpty ? stdout.trimRight() : null,
        null,
        exitCode == 0 && stdout.trim().isNotEmpty ? null : _mapExit(exitCode),
      );
    List<Object?> events;
    try {
      if (mode == 'single_json') {
        events = [jsonDecode(stdout)];
      } else {
        events = stdout
            .split(RegExp(r'\r?\n'))
            .where((line) => line.isNotEmpty)
            .map(jsonDecode)
            .toList();
      }
    } on Object {
      return const _InterpretedOutput(
        null,
        null,
        WorkerIssueCode.providerFailure,
      );
    }
    Object? finalText;
    String? sessionId;
    String? terminalStatus;
    var markedSuccess = false;
    var markedFailure = false;
    var providerError = false;
    var providerErrorText = '';
    var terminalObserved = false;
    for (final event in events) {
      if (event is! Map) continue;
      final profileSession = _profile.session;
      if (profileSession['supported'] == true &&
          profileSession['extract'] is String) {
        final value = _select(event, profileSession['extract'] as String);
        if (value is String && value.isNotEmpty) {
          if (!_validSessionId(value)) {
            return const _InterpretedOutput(
              null,
              null,
              WorkerIssueCode.providerFailure,
            );
          }
          if (sessionId != null && sessionId != value) {
            return const _InterpretedOutput(
              null,
              null,
              WorkerIssueCode.providerFailure,
            );
          }
          sessionId = value;
        }
      }
      for (final ruleRaw in _list(execution['events'])) {
        final rule = _map(ruleRaw);
        if (!_matches(event, rule['when'])) continue;
        for (final actionRaw in _list(rule['actions'])) {
          final action = _map(actionRaw);
          final type = action['type'];
          final value = action['selector'] == null
              ? null
              : _select(event, _string(action['selector']));
          if (type == 'set_session' && value is String && value.isNotEmpty) {
            if (!_validSessionId(value)) {
              return const _InterpretedOutput(
                null,
                null,
                WorkerIssueCode.providerFailure,
              );
            }
            if (sessionId != null && sessionId != value) {
              return const _InterpretedOutput(
                null,
                null,
                WorkerIssueCode.providerFailure,
              );
            }
            sessionId = value;
          }
          if (type == 'set_final_text' && value is String) finalText = value;
          if (type == 'set_terminal_status' && value is String)
            terminalStatus = value;
          if (type == 'set_provider_error' &&
              value != null &&
              value != false &&
              value != '') {
            providerError = true;
            providerErrorText = value is String
                ? value.substring(0, value.length.clamp(0, 4096))
                : 'provider error';
          }
          if (type == 'mark_success') markedSuccess = true;
          if (type == 'mark_failure') markedFailure = true;
        }
      }
    }
    if (mode == 'single_json' && finalText == null) finalText = stdout;
    terminalObserved =
        markedSuccess ||
        markedFailure ||
        terminalStatus != null ||
        providerError;
    final text = finalText is String && finalText.length <= 512 * 1024
        ? finalText
        : null;
    final implicitTextSuccess = mode == 'plain_text' && exitCode == 0;
    final successful =
        exitCode == 0 &&
        !markedFailure &&
        !providerError &&
        (markedSuccess || implicitTextSuccess) &&
        text != null &&
        text.isNotEmpty;
    final requireMatch = _profile.session['requireObservedIdMatch'] == true;
    if (successful &&
        durable &&
        requireMatch &&
        (sessionId == null ||
            (priorSession != null && sessionId != priorSession))) {
      return const _InterpretedOutput(
        null,
        null,
        WorkerIssueCode.providerFailure,
      );
    }
    if (successful) return _InterpretedOutput(text, sessionId, null);

    final mappings = _list(_map(_profile.json['errors'])['mappings']);
    for (final raw in mappings) {
      final mapping = _map(raw);
      final evidence = _map(mapping['evidence']);
      final kind = evidence['kind'];
      final matched = switch (kind) {
        'exit_code' => evidence['value'] == exitCode,
        'terminal_status' => evidence['value'] == terminalStatus,
        'missing_terminal' => !terminalObserved,
        'structured_provider_error' => providerError,
        'stderr_pattern' => _stderrPattern(
          _string(evidence['patternId']),
          providerErrorText.isNotEmpty ? providerErrorText : stderr,
        ),
        _ => false,
      };
      if (matched)
        return _InterpretedOutput(null, null, _string(mapping['issueCode']));
    }
    return const _InterpretedOutput(
      null,
      null,
      WorkerIssueCode.providerFailure,
    );
  }

  bool _stderrPattern(String patternId, String text) {
    final patterns = <String, RegExp>{
      'cancelled': RegExp(
        r'cancelled|canceled|interrupted|user interrupted',
        caseSensitive: false,
      ),
      'deadline_exceeded': RegExp(
        r'timeout|timed out|deadline exceeded',
        caseSensitive: false,
      ),
      'provider_tool_unavailable': RegExp(
        r'enoent|executable not found|command not found',
        caseSensitive: false,
      ),
      'provider_authentication_required': RegExp(
        r'unauthori[sz]ed|authentication required|not authenticated|sign in|login required|credentials? (missing|expired|invalid)',
        caseSensitive: false,
      ),
      'permission_denied': RegExp(
        r'permission denied|approval denied|sandbox.*(denied|blocked)',
        caseSensitive: false,
      ),
      'quota_exhausted': RegExp(
        r'quota.{0,40}(exceeded|exhausted)|rate limit',
        caseSensitive: false,
      ),
      'provider_unavailable': RegExp(
        r'provider unavailable|service unavailable|temporarily unavailable',
        caseSensitive: false,
      ),
      'provider_failure': RegExp(r'.+', dotAll: true),
    };
    return patterns[patternId]?.hasMatch(text) ?? false;
  }

  bool _matches(Object? event, Object? conditions) {
    if (conditions is! List) return false;
    for (final raw in conditions) {
      final condition = _map(raw);
      final value = _select(event, _string(condition['selector']));
      switch (condition['kind']) {
        case 'equals':
          if (value != condition['value']) return false;
        case 'not_equals':
          if (value == null || value == condition['value']) return false;
        case 'one_of':
          if (!_list(condition['values']).contains(value)) return false;
        case 'exists':
          if ((value != null) != (condition['exists'] == true)) return false;
        case 'type_is':
          final actual = value == null
              ? 'null'
              : value is List
              ? 'array'
              : value is Map
              ? 'object'
              : value is num
              ? 'number'
              : value is bool
              ? 'boolean'
              : 'string';
          if (actual != condition['value']) return false;
        default:
          return false;
      }
    }
    return true;
  }

  Object? _select(Object? root, String selector) {
    if (!RegExp(r'^\$(?:\.[A-Za-z_][A-Za-z0-9_]*)+$').hasMatch(selector) ||
        selector.length > 256 ||
        selector.split('.').length - 1 > 16)
      return null;
    Object? current = root;
    for (final part in selector.substring(2).split('.')) {
      if (current is! Map || !current.containsKey(part)) return null;
      current = current[part];
    }
    return current;
  }

  bool _validSessionId(String value) =>
      value.length <= 256 && RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);

  WorkerErrorFrame _notInitialized(String requestId, {String? assignmentId}) =>
      WorkerErrorFrame(
        requestId: requestId,
        assignmentId: assignmentId,
        code: WorkerIssueCode.workerInternalFailure,
        message: 'Engine must complete initialize before this request',
      );

  String _mapExit(int exitCode) {
    final mappings = _map(_profile.json['errors'])['mappings'];
    if (mappings is List)
      for (final raw in mappings) {
        final mapping = _map(raw);
        final evidence = _map(mapping['evidence']);
        if (evidence['kind'] == 'exit_code' && evidence['value'] == exitCode)
          return _string(mapping['issueCode']);
      }
    return WorkerIssueCode.providerFailure;
  }

  Map<String, Object?> _diagnosticContext({
    String? requestId,
    String? assignmentId,
    String? providerToolVersion,
    int? durationMs,
    String? errorCode,
    String? probeStage,
    String? failureLayer,
  }) => {
    if (requestId != null) 'requestId': requestId,
    if (assignmentId != null) 'assignmentId': assignmentId,
    'workerTypeId': _profile.workerTypeId,
    'engineVersion': options.engineVersion,
    'profileDefinitionId': _profile.definitionId,
    'profileReleaseVersion': _profile.releaseVersion,
    'profileSchemaVersion': _profile.schemaVersion,
    'providerToolName': _string(_profile.providerTool['name']),
    if (providerToolVersion != null) 'providerToolVersion': providerToolVersion,
    if (durationMs != null) 'durationMs': durationMs,
    if (errorCode != null) 'errorCode': errorCode,
    if (probeStage != null) 'probeStage': probeStage,
    if (failureLayer != null) 'failureLayer': failureLayer,
  };

  String _failureLayer(String code) => switch (code) {
    WorkerIssueCode.workerInternalFailure ||
    WorkerIssueCode.malformedFrame ||
    WorkerIssueCode.engineVersionMismatch ||
    WorkerIssueCode.profileIdentityMismatch ||
    WorkerIssueCode.workerTypeMismatch => 'engine',
    WorkerIssueCode.unsupportedProviderToolVersion ||
    WorkerIssueCode.modelNotSupported ||
    WorkerIssueCode.sessionResumeFailed => 'profile',
    _ => 'provider_tool',
  };

  Future<void> _write(IOSink sink, WorkerFrame frame) async {
    if (frame is ProbeResult) {
      final timer = _operationStarts.remove(frame.requestId);
      _logger.log(
        frame.ready ? 'info' : 'warning',
        'engine.probe.completed',
        context: _diagnosticContext(
          requestId: frame.requestId,
          providerToolVersion: frame.providerToolVersion,
          durationMs: timer?.elapsedMilliseconds,
          errorCode: frame.issueCode,
          probeStage: frame.mode.name,
          failureLayer:
              frame.issueCode == null ? null : _failureLayer(frame.issueCode!),
        ),
      );
    } else if (frame is WorkerResult || frame is WorkerErrorFrame) {
      final requestId = frame.requestId;
      final timer = _operationStarts.remove(requestId);
      final error = frame is WorkerErrorFrame ? frame : null;
      final assignmentId = frame is WorkerResult
          ? frame.assignmentId
          : error?.assignmentId;
      _logger.log(
        error == null ? 'info' : 'warning',
        error == null ? 'engine.assignment.completed' : 'engine.assignment.failed',
        context: _diagnosticContext(
          requestId: requestId,
          assignmentId: assignmentId,
          durationMs: timer?.elapsedMilliseconds,
          errorCode: error?.code,
          failureLayer: error == null ? null : _failureLayer(error.code),
        ),
      );
    }
    sink.writeln(frame.encode());
    await sink.flush();
  }
}

class EngineProviderException implements Exception {
  const EngineProviderException(this.issueCode, this.safeMessage);
  final String issueCode;
  final String safeMessage;
}

class _ProbeOutcome {
  const _ProbeOutcome(this.check, this.issueCode);
  final ProbeCheck check;
  final String? issueCode;
}

class _InterpretedOutput {
  const _InterpretedOutput(this.finalText, this.sessionId, this.issueCode);
  final String? finalText;
  final String? sessionId;
  final String? issueCode;
}

bool _isSemver(String value) => RegExp(
  r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$',
).hasMatch(value);
String? _extractSemver(String value) {
  final match = RegExp(
    r'(?<![A-Za-z0-9])v?((?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?)(?![A-Za-z0-9])',
  ).firstMatch(value);
  final version = match?.group(1);
  return version != null && isSemanticVersion(version) ? version : null;
}

Map<String, Object?> _map(Object? value) => value is Map
    ? Map<String, Object?>.from(value)
    : throw const FormatException('expected Profile object');
List<Object?> _list(Object? value) => value is List
    ? value.cast<Object?>()
    : throw const FormatException('expected Profile array');
List<String> _stringList(Object? value) =>
    _list(value).map((item) => _string(item)).toList();
List<int> _intList(Object? value) => _list(value).map(_int).toList();
String _string(Object? value) => value is String
    ? value
    : throw const FormatException('expected Profile string');
int _int(Object? value) => value is int
    ? value
    : throw const FormatException('expected Profile integer');
String _requestIdFromLine(String line) {
  try {
    final value = jsonDecode(line);
    if (value is Map &&
        value['requestId'] is String &&
        (value['requestId'] as String).isNotEmpty)
      return (value['requestId'] as String).substring(
        0,
        (value['requestId'] as String).length.clamp(0, 128),
      );
  } on Object {}
  return 'invalid-frame';
}
