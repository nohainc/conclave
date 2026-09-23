import 'dart:convert';
import 'dart:io';

import 'package:conclave_openai_worker/openai_manifest.dart';
import 'package:conclave_openai_worker/openai_worker.dart';

Future<void> main() async {
  final worker = OpenAiWorker(invokeOpenAi);
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    final request = jsonDecode(line) as Map<String, dynamic>;
    try {
      final result = switch (request['method']) {
        'initialize' => {
            'workerId': openAiWorkerManifest['workerId'],
            'version': openAiWorkerManifest['version'],
            'protocolVersion': openAiWorkerManifest['protocolVersion'],
            'runtimeLanguage': 'dart',
            'capabilities': openAiWorkerManifest['capabilities'],
          },
        'health' => {
            'status': Platform.environment['OPENAI_API_KEY']?.isNotEmpty == true
                ? 'healthy'
                : 'unavailable',
            'authenticated':
                Platform.environment['OPENAI_API_KEY']?.isNotEmpty == true,
          },
        'describe' => openAiWorkerManifest,
        'execute' => await _execute(worker, request),
        'cancel' => {'cancelled': false},
        'shutdown' => {'stopped': true},
        _ => throw StateError('unsupported method'),
      };
      stdout.writeln(jsonEncode(
          {'jsonrpc': '2.0', 'id': request['id'], 'result': result}));
      await stdout.flush();
    } on Object catch (error) {
      stdout.writeln(jsonEncode({
        'jsonrpc': '2.0',
        'id': request['id'],
        'error': {'code': -32000, 'message': '$error'},
      }));
      await stdout.flush();
    }
  }
}

Future<Map<String, Object?>> _execute(
  OpenAiWorker worker,
  Map<String, dynamic> request,
) async {
  final params = Map<String, Object?>.from(request['params'] as Map);
  final snapshot = params['snapshot'] is Map
      ? Map<String, Object?>.from(params['snapshot'] as Map)
      : const <String, Object?>{};
  final input = params['input'] is Map
      ? Map<String, Object?>.from(params['input'] as Map)
      : const <String, Object?>{};
  final config = params['config'] is Map
      ? Map<String, Object?>.from(params['config'] as Map)
      : const <String, Object?>{};
  final objective = params['objective'] ?? input['objective'];
  final model =
      params['model'] ?? config['model'] ?? snapshot['model'] ?? 'gpt-4o-mini';
  final credentialProfileId = snapshot['credentialProfileId'];
  if (objective is! String || model is! String || objective.trim().isEmpty) {
    throw const FormatException('objective and model are required');
  }
  final result = await worker.executeStructured(
    apiKey: Platform.environment['OPENAI_API_KEY'],
    model: model,
    prompt: buildOpenAiPrompt(objective, {...config, ...input}),
  );
  return {
    'status': 'completed',
    'summary': 'OpenAI worker completed the assignment',
    if (credentialProfileId is String)
      'credentialProfileId': credentialProfileId,
    'model': model,
    'usage': {
      'inputTokens': result.usage.inputTokens,
      'outputTokens': result.usage.outputTokens,
      'totalTokens': result.usage.inputTokens + result.usage.outputTokens,
    },
    'output': result.output,
    'evidence': {
      'metrics': {
        'inputTokens': result.usage.inputTokens,
        'outputTokens': result.usage.outputTokens,
        'totalTokens': result.usage.inputTokens + result.usage.outputTokens,
      },
    },
  };
}
