import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';

import 'platform_runtime.dart';
import 'tool_profile_release_verifier.dart';

const cliWorkerEngineVersion = '1.0.0';

/// Runs one isolated generic Engine process for one passive or live probe.
final class CliWorkerEngineSupervisor {
  CliWorkerEngineSupervisor({
    required this.engineExecutable,
    this.engineArgumentsPrefix = const [],
    this.environmentOverrides = const {},
    PlatformRuntime? platformRuntime,
    this.maxFrameBytes = WorkerProtocolLimits.maxFrameBytes,
    this.maxStderrBytes = 64 * 1024,
  }) : _platformRuntime = platformRuntime ?? currentPlatformRuntime;

  final String engineExecutable;
  final List<String> engineArgumentsPrefix;
  final Map<String, String> environmentOverrides;
  final PlatformRuntime _platformRuntime;
  final int maxFrameBytes;
  final int maxStderrBytes;

  Future<ProbeResult> probe(
    ToolProfileReleaseAdmission release, {
    required File profileFile,
    required Directory stateDirectory,
    required WorkerProbeMode mode,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final boundedTimeout = timeout >
            const Duration(
              milliseconds: WorkerProtocolLimits.maxProbeTimeoutMs,
            )
        ? const Duration(milliseconds: WorkerProtocolLimits.maxProbeTimeoutMs)
        : timeout;
    if (boundedTimeout < const Duration(milliseconds: 100)) {
      throw ArgumentError.value(
          timeout, 'timeout', 'probe timeout is too short');
    }
    await stateDirectory.create(recursive: true);
    final timer = Stopwatch()..start();
    Process? process;
    _CliEngineChannel? channel;
    var stopped = false;
    try {
      process = await _platformRuntime.startIsolatedProcess(
        engineExecutable,
        [
          ...engineArgumentsPrefix,
          '--profile',
          profileFile.path,
          '--engine-version',
          cliWorkerEngineVersion,
          '--state-directory',
          stateDirectory.path,
        ],
        workingDirectory: stateDirectory.path,
        environment: environmentOverrides,
        includeParentEnvironment: true,
      );
      channel = _CliEngineChannel(
        process,
        maxFrameBytes: maxFrameBytes,
        maxStderrBytes: maxStderrBytes,
      );
      final initialized = await channel.exchange(
        InitializeRequest(
          requestId: 'engine-init-${DateTime.now().microsecondsSinceEpoch}',
          workerTypeId: release.logicalWorkerTypeId,
          expectedEngineVersion: cliWorkerEngineVersion,
          profileDefinitionId: release.profileDefinitionId,
          profileReleaseVersion: release.releaseVersion.toString(),
          profileDigest: release.payloadDigest,
        ),
        _remaining(boundedTimeout, timer),
      );
      if (initialized is! InitializeResult ||
          initialized.workerTypeId != release.logicalWorkerTypeId ||
          initialized.engineVersion != cliWorkerEngineVersion ||
          initialized.profileDefinitionId != release.profileDefinitionId ||
          initialized.profileReleaseVersion !=
              release.releaseVersion.toString() ||
          initialized.profileSchemaVersion !=
              release.profile['schemaVersion'] ||
          !_sameCapabilities(initialized.capabilities, release.profile)) {
        throw const FormatException('CLI Worker Engine initialize mismatch');
      }
      final result = await channel.exchange(
        ProbeRequest(
          requestId: 'engine-probe-${DateTime.now().microsecondsSinceEpoch}',
          mode: mode,
          timeoutMs: boundedTimeout.inMilliseconds,
        ),
        _remaining(boundedTimeout, timer),
      );
      if (result is! ProbeResult || result.mode != mode) {
        throw const FormatException(
            'CLI Worker Engine probe response mismatch');
      }
      if (result.providerToolName != null &&
          result.providerToolName != release.providerToolName) {
        throw const FormatException(
            'CLI Worker Engine provider identity mismatch');
      }
      await process.stdin.close();
      final exitCode =
          await process.exitCode.timeout(const Duration(seconds: 2));
      if (exitCode != 0) {
        throw const FormatException('CLI Worker Engine exited unsuccessfully');
      }
      stopped = true;
      return result;
    } on TimeoutException {
      throw const CliWorkerEngineProbeException(
        WorkerIssueCode.deadlineExceeded,
        'Provider probe exceeded its deadline.',
      );
    } on ProcessException {
      throw const CliWorkerEngineProbeException(
        WorkerIssueCode.providerToolUnavailable,
        'CLI Worker Engine could not be started.',
      );
    } finally {
      if (process != null && !stopped) {
        await _platformRuntime.terminateProcessTree(process, force: true);
      }
      await channel?.dispose();
    }
  }

  Duration _remaining(Duration timeout, Stopwatch timer) {
    final value = timeout - timer.elapsed;
    if (value <= Duration.zero) {
      throw TimeoutException('probe deadline elapsed');
    }
    return value;
  }

  bool _sameCapabilities(List<String> values, Map<String, Object?> profile) {
    final raw = profile['capabilities'];
    if (raw is! List || raw.length != values.length) return false;
    return values.toSet().length == values.length &&
        values.toSet().containsAll(
              raw.whereType<String>(),
            );
  }
}

final class CliWorkerEngineProbeException implements Exception {
  const CliWorkerEngineProbeException(this.issueCode, this.safeMessage);

  final String issueCode;
  final String safeMessage;
}

final class _CliEngineChannel {
  _CliEngineChannel(
    this.process, {
    required this.maxFrameBytes,
    required this.maxStderrBytes,
  }) : _lines = StreamIterator<String>(
          process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter()),
        ) {
    _stderrTask = _drainStderr();
  }

  final Process process;
  final int maxFrameBytes;
  final int maxStderrBytes;
  final StreamIterator<String> _lines;
  late final Future<void> _stderrTask;
  int _stderrBytes = 0;

  Future<WorkerFrame> exchange(WorkerFrame request, Duration timeout) async {
    process.stdin.writeln(request.encode());
    await process.stdin.flush();
    if (!await _lines.moveNext().timeout(timeout)) {
      throw TimeoutException('CLI Worker Engine closed its protocol stream');
    }
    final line = _lines.current;
    if (utf8.encode(line).length > maxFrameBytes) {
      throw const FormatException('CLI Worker Engine frame exceeds the limit');
    }
    final frame = decodeWorkerFrame(line);
    if (frame.requestId != request.requestId) {
      throw const FormatException('CLI Worker Engine request ID mismatch');
    }
    return frame;
  }

  Future<void> _drainStderr() async {
    await for (final bytes in process.stderr) {
      _stderrBytes =
          (_stderrBytes + bytes.length).clamp(0, maxStderrBytes).toInt();
      // Continue draining after the diagnostic cap; raw provider/engine text
      // is intentionally not retained or returned to the UI.
    }
  }

  Future<void> dispose() async {
    await _lines.cancel();
    await _stderrTask;
  }
}
