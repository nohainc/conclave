import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'work_request_input_staging.dart';

/// One uploaded input this Workspace has to download.
class PendingWorkRequestInput {
  const PendingWorkRequestInput({
    required this.fileId,
    required this.workRequestId,
    required this.name,
    required this.sizeBytes,
    required this.contentDigest,
  });

  final String fileId;
  final String workRequestId;
  final String name;
  final int sizeBytes;
  final String contentDigest;

  static PendingWorkRequestInput? fromJson(Object? value) {
    if (value is! Map) return null;
    final fileId = value['fileId'];
    final workRequestId = value['workRequestId'];
    final sizeBytes = value['sizeBytes'];
    final digest = value['contentDigest'];
    if (!isWorkRequestInputId(fileId) ||
        workRequestId is! String ||
        sizeBytes is! int ||
        digest is! String) {
      return null;
    }
    final name = value['name'];
    return PendingWorkRequestInput(
      fileId: fileId as String,
      workRequestId: workRequestId,
      name: name is String ? name : 'Attachment',
      sizeBytes: sizeBytes,
      contentDigest: digest,
    );
  }
}

/// Cloud side of Input Delivery v1 as seen by the Service.
abstract class InputDeliveryCloud {
  Future<List<PendingWorkRequestInput>> listPending();
  Future<Stream<List<int>>> download(String fileId);
  Future<void> confirmDelivered(String fileId, String contentDigest);
  Future<void> reportAttempt(String fileId,
      {required bool finalAttempt, required String message});
}

/// HTTPS client authenticated with the Workspace runtime credential. File
/// bytes stream from Cloud storage, so no transport frame limit applies.
class HttpInputDeliveryCloud implements InputDeliveryCloud {
  HttpInputDeliveryCloud({
    required this.cloudUri,
    required this.workspaceRuntimeId,
    required this.authToken,
    HttpClient? client,
    this.timeout = const Duration(seconds: 30),
  }) : _client = client ?? HttpClient();

  final Uri cloudUri;
  final String workspaceRuntimeId;
  final String authToken;
  final Duration timeout;
  final HttpClient _client;

  Uri _uri(String path) {
    final scheme = switch (cloudUri.scheme) {
      'wss' => 'https',
      'ws' => 'http',
      'https' || 'http' => cloudUri.scheme,
      _ => throw ArgumentError('Cloud URL must use HTTP or WebSocket'),
    };
    final existing = cloudUri.path.replaceFirst(RegExp(r'/$'), '');
    final prefix =
        existing.isEmpty || existing.endsWith('/api/workspace-gateway/connect')
            ? ''
            : existing;
    return cloudUri.replace(
      scheme: scheme,
      path: '$prefix$path',
      queryParameters: {'workspaceRuntimeId': workspaceRuntimeId},
      fragment: null,
      userInfo: '',
    );
  }

  Future<HttpClientResponse> _send(String method, String path,
      {Map<String, Object?>? body}) async {
    final request = await _client.openUrl(method, _uri(path)).timeout(timeout);
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $authToken');
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    return request.close().timeout(timeout);
  }

  Future<void> _expectOk(HttpClientResponse response) async {
    final text = await utf8.decodeStream(response).timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('HTTP ${response.statusCode}: '
          '${text.length > 200 ? text.substring(0, 200) : text}');
    }
  }

  @override
  Future<List<PendingWorkRequestInput>> listPending() async {
    final response = await _send('GET', '/api/workspace-runtime/inputs');
    final text = await utf8.decodeStream(response).timeout(timeout);
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('Input list returned HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(text);
    final inputs = decoded is Map ? decoded['inputs'] : null;
    if (inputs is! List) return const [];
    return inputs
        .map(PendingWorkRequestInput.fromJson)
        .whereType<PendingWorkRequestInput>()
        .toList(growable: false);
  }

  @override
  Future<Stream<List<int>>> download(String fileId) async {
    final response =
        await _send('GET', '/api/workspace-runtime/inputs/$fileId/content');
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw HttpException('Download returned HTTP ${response.statusCode}');
    }
    // An idle stream is a stalled transfer; the attempt restarts the file.
    return response.timeout(timeout);
  }

  @override
  Future<void> confirmDelivered(String fileId, String contentDigest) async =>
      _expectOk(await _send(
          'POST', '/api/workspace-runtime/inputs/$fileId/delivered',
          body: {'contentDigest': contentDigest}));

  @override
  Future<void> reportAttempt(String fileId,
          {required bool finalAttempt, required String message}) async =>
      _expectOk(await _send(
          'POST', '/api/workspace-runtime/inputs/$fileId/attempt',
          body: {'final': finalAttempt, 'message': message}));
}

/// Downloads uploaded Work Request inputs as soon as Cloud lists them, while
/// the user may still be uploading the rest. Files download in parallel; a
/// failed attempt discards the partial file and restarts it from scratch.
/// After [maxAttempts] the input is reported failed, which fails its request
/// before any Worker starts.
class InputDeliveryAgent {
  InputDeliveryAgent({
    required this.cloud,
    required this.staging,
    this.maxConcurrent = 3,
    this.maxAttempts = 3,
    this.activePollInterval = const Duration(seconds: 2),
    this.idlePollInterval = const Duration(seconds: 30),
    this.retryDelay = const Duration(seconds: 2),
  });

  final InputDeliveryCloud cloud;
  final WorkRequestInputStaging staging;
  final int maxConcurrent;
  final int maxAttempts;
  final Duration activePollInterval;
  final Duration idlePollInterval;
  final Duration retryDelay;

  final _inFlight = <String, Future<void>>{};
  final _waiting = <PendingWorkRequestInput>[];
  Timer? _timer;
  bool _polling = false;
  bool _pollAgain = false;
  bool _stopped = false;

  /// Starts the idle poll and checks immediately.
  void start() {
    _stopped = false;
    wake();
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
  }

  /// Handles `input.available` and session readiness: lists inputs now.
  void wake() {
    if (_stopped) return;
    if (_polling) {
      _pollAgain = true;
      return;
    }
    unawaited(_poll());
  }

  Future<void> _poll() async {
    _polling = true;
    _timer?.cancel();
    var found = false;
    try {
      final pending = await cloud.listPending();
      for (final input in pending) {
        if (_inFlight.containsKey(input.fileId) ||
            _waiting.any((item) => item.fileId == input.fileId)) {
          found = true;
          continue;
        }
        found = true;
        _waiting.add(input);
      }
      _drain();
    } on Object {
      // Unreachable Cloud: the next poll retries.
    } finally {
      _polling = false;
    }
    if (_stopped) return;
    if (_pollAgain) {
      _pollAgain = false;
      unawaited(_poll());
      return;
    }
    _timer = Timer(
        found || _inFlight.isNotEmpty ? activePollInterval : idlePollInterval,
        wake);
  }

  void _drain() {
    while (_inFlight.length < maxConcurrent && _waiting.isNotEmpty) {
      final input = _waiting.removeAt(0);
      _inFlight[input.fileId] = _deliver(input).whenComplete(() {
        _inFlight.remove(input.fileId);
        if (!_stopped) _drain();
      });
    }
  }

  Future<void> _deliver(PendingWorkRequestInput input) async {
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        if (!await staging.contains(input.fileId)) {
          await staging.stageStream(
            fileId: input.fileId,
            sizeBytes: input.sizeBytes,
            contentDigest: input.contentDigest,
            content: await cloud.download(input.fileId),
          );
        } else {
          // Verify a copy left by an earlier run before confirming it.
          await staging.read(
              fileId: input.fileId,
              sizeBytes: input.sizeBytes,
              contentDigest: input.contentDigest);
        }
        await cloud.confirmDelivered(input.fileId, input.contentDigest);
        return;
      } on Object catch (error) {
        final message = error is WorkRequestInputStagingException
            ? error.message
            : 'download failed';
        final finalAttempt = attempt == maxAttempts;
        try {
          await cloud.reportAttempt(input.fileId,
              finalAttempt: finalAttempt, message: message);
        } on Object {
          // Cloud's idle deadline still ends the request.
        }
        if (finalAttempt || _stopped) return;
        await Future<void>.delayed(retryDelay * attempt);
      }
    }
  }

  /// Ensures [fileId] is stored, downloading it when this Workspace no longer
  /// has it (a later retry or step after retention). Does not confirm.
  Future<void> ensure({
    required String fileId,
    required int sizeBytes,
    required String contentDigest,
  }) async {
    final running = _inFlight[fileId];
    if (running != null) await running;
    if (await staging.contains(fileId)) return;
    await staging.stageStream(
      fileId: fileId,
      sizeBytes: sizeBytes,
      contentDigest: contentDigest,
      content: await cloud.download(fileId),
    );
  }
}
