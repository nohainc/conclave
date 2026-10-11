import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:conclave_cli_worker_runtime/conclave_cli_worker_runtime.dart';
import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';

/// Discovery parses bounded CLI metadata, never executes a model request.
List<DiscoveredModel> parseDiscoveredModels(String output, String idPrefix) {
  if (utf8.encode(output).length > 64 * 1024)
    throw const FormatException('Model catalog exceeds limit');
  final models = <String, DiscoveredModel>{};
  for (final line in const LineSplitter().convert(output)) {
    if (line.trim().isEmpty) continue;
    final fields = line.split('\t');
    if (fields.length < 2 || fields.length > 4)
      throw const FormatException('Expected model ID and label');
    final id = fields[0].trim();
    if (idPrefix.isNotEmpty && !id.startsWith(idPrefix)) continue;
    final efforts =
        fields.length < 3 || fields[2].trim().isEmpty || fields[2].trim() == '-'
        ? const <String>[]
        : fields[2]
              .split(',')
              .map((effort) => effort.trim())
              .where((effort) => effort.isNotEmpty)
              .toList(growable: false);
    final defaultEffort =
        fields.length < 4 || fields[3].trim().isEmpty || fields[3].trim() == '-'
        ? null
        : fields[3].trim();
    final model = DiscoveredModel(
      id: id,
      name: fields[1].trim(),
      supportedReasoningEfforts: efforts,
      defaultReasoningEffort: defaultEffort,
    );
    if (models.containsKey(id))
      throw const FormatException('Duplicate model ID');
    models[id] = model;
    if (models.length > 128)
      throw const FormatException('Model catalog exceeds limit');
  }
  return models.values.toList();
}

/// Queries the Codex app-server model catalog over its newline-delimited
/// JSON-RPC transport. The app-server is intentionally used only for
/// discovery here; execution remains owned by the generic CLI engine.
Future<List<DiscoveredModel>> discoverCodexAppServerModels({
  required String executable,
  required List<String> arguments,
  required Map<String, String> environment,
  required String workingDirectory,
  required String idPrefix,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
    includeParentEnvironment: false,
    runInShell: false,
  );
  final lines = StreamIterator(
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
  );
  const cleanup = WorkerProcessCleanup();
  // Keep stderr drained so a noisy app-server cannot block its stdout.
  final stderrDrain = process.stderr.drain<void>();
  final deadline = DateTime.now().add(timeout);
  try {
    await _sendAppServerRequest(process.stdin, {
      'id': 1,
      'method': 'initialize',
      'params': {
        'clientInfo': {
          'name': 'conclave-cli-worker-engine',
          'version': '1.1.0',
        },
        'capabilities': null,
      },
    });
    await _readAppServerResponse(lines, 1, deadline);
    final models = <DiscoveredModel>[];
    final seen = <String>{};
    String? cursor;
    for (var page = 0; page < 8; page++) {
      final requestId = page + 2;
      await _sendAppServerRequest(process.stdin, {
        'id': requestId,
        'method': 'model/list',
        'params': {'cursor': cursor, 'includeHidden': false, 'limit': 128},
      });
      final response = await _readAppServerResponse(lines, requestId, deadline);
      for (final model in parseCodexAppServerModels(response, idPrefix)) {
        if (!seen.add(model.id)) {
          throw const FormatException('Duplicate model ID');
        }
        models.add(model);
      }
      if (models.length > 128) {
        throw const FormatException('Model catalog exceeds limit');
      }
      final next = response['nextCursor'];
      if (next == null) return models;
      if (next is! String || next.isEmpty) {
        throw const FormatException('Codex app-server pagination is invalid');
      }
      cursor = next;
    }
    throw const FormatException('Codex app-server pagination exceeds limit');
  } finally {
    await lines.cancel();
    await cleanup.terminate(process, grace: const Duration(milliseconds: 500));
    await stderrDrain.catchError((_) {});
  }
}

Future<void> _sendAppServerRequest(IOSink sink, Map<String, Object?> request) {
  sink.writeln(jsonEncode(request));
  return sink.flush();
}

Future<Map<String, Object?>> _readAppServerResponse(
  StreamIterator<String> lines,
  int requestId,
  DateTime deadline,
) async {
  while (true) {
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      throw TimeoutException('Codex app-server discovery timed out');
    }
    if (!await lines.moveNext().timeout(remaining)) {
      throw const FormatException('Codex app-server closed before responding');
    }
    final line = lines.current;
    if (utf8.encode(line).length > 64 * 1024) {
      throw const FormatException('Codex app-server response exceeds limit');
    }
    final decoded = jsonDecode(line);
    if (decoded is! Map) {
      throw const FormatException('Codex app-server response is invalid');
    }
    final value = Map<String, Object?>.from(decoded);
    if (value['id'] != requestId) continue;
    if (value['error'] != null) {
      throw FormatException(
        'Codex app-server request failed: ${value['error']}',
      );
    }
    final result = value['result'];
    if (result is! Map) {
      throw const FormatException('Codex app-server result is invalid');
    }
    return Map<String, Object?>.from(result);
  }
}

List<DiscoveredModel> parseCodexAppServerModels(
  Map<String, Object?> response,
  String idPrefix,
) {
  final data = response['data'];
  if (data is! List) {
    throw const FormatException('Codex app-server model list is invalid');
  }
  final models = <DiscoveredModel>[];
  final ids = <String>{};
  for (final raw in data) {
    if (raw is! Map) {
      throw const FormatException('Codex app-server model entry is invalid');
    }
    final value = Map<String, Object?>.from(raw);
    if (value['hidden'] == true) continue;
    final id = (value['id'] ?? value['model']);
    if (id is! String || id.isEmpty) {
      throw const FormatException('Codex app-server model ID is invalid');
    }
    if (idPrefix.isNotEmpty && !id.startsWith(idPrefix)) continue;
    if (!ids.add(id)) {
      throw const FormatException('Duplicate model ID');
    }
    final name =
        value['displayName'] is String &&
            (value['displayName'] as String).isNotEmpty
        ? value['displayName'] as String
        : id;
    final efforts = <String>[];
    final rawEfforts = value['supportedReasoningEfforts'];
    if (rawEfforts is List) {
      for (final rawEffort in rawEfforts) {
        if (rawEffort is! Map || rawEffort['reasoningEffort'] is! String) {
          throw const FormatException(
            'Codex app-server reasoning effort is invalid',
          );
        }
        final effort = rawEffort['reasoningEffort'] as String;
        if (!efforts.contains(effort)) efforts.add(effort);
      }
    } else if (rawEfforts != null) {
      throw const FormatException(
        'Codex app-server reasoning efforts are invalid',
      );
    }
    final defaultEffort = value['defaultReasoningEffort'];
    if (defaultEffort != null &&
        (defaultEffort is! String || !efforts.contains(defaultEffort))) {
      throw const FormatException(
        'Codex app-server default reasoning effort is invalid',
      );
    }
    models.add(
      DiscoveredModel(
        id: id,
        name: name,
        supportedReasoningEfforts: efforts,
        defaultReasoningEffort: defaultEffort as String?,
      ),
    );
    if (models.length > 128) {
      throw const FormatException('Model catalog exceeds limit');
    }
  }
  return models;
}

class ModelDiscoveryCache {
  ModelDiscoveryCache(String statePath)
    : file = File('$statePath/model-catalog.json');
  final File file;
  Future<DiscoveredModelCatalog?> load(String digest, String version) async {
    try {
      if (await file.length() > 128 * 1024) return null;
      final catalog = DiscoveredModelCatalog.fromJson(
        Map<String, Object?>.from(jsonDecode(await file.readAsString()) as Map),
      );
      return catalog.profileDigest == digest &&
              catalog.providerToolVersion == version
          ? catalog
          : null;
    } on Object {
      return null;
    }
  }

  Future<void> save(DiscoveredModelCatalog catalog) async {
    await file.parent.create(recursive: true);
    final temp = File(
      '${file.path}.tmp.$pid.${DateTime.now().microsecondsSinceEpoch}',
    );
    await temp.writeAsString(jsonEncode(catalog.toJson()), flush: true);
    await temp.rename(file.path);
  }
}
