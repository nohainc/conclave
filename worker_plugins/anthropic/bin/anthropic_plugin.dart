import 'dart:convert';
import 'dart:io';

import 'package:conclave_anthropic_plugin/anthropic_manifest.dart';
import 'package:conclave_anthropic_plugin/anthropic_worker.dart';

Future<void> main() async {
  final worker = AnthropicWorker(invokeAnthropic);
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    final request = jsonDecode(line) as Map<String, dynamic>;
    try {
      final result = switch (request['method']) {
        'initialize' => {
            'pluginId': anthropicPluginManifest['pluginId'],
            'version': anthropicPluginManifest['version'],
            'protocolVersion': anthropicPluginManifest['protocolVersion'],
            'runtimeLanguage': 'dart',
            'capabilities': anthropicPluginManifest['capabilities'],
          },
        'health' => {
            'status':
                Platform.environment['ANTHROPIC_API_KEY']?.isNotEmpty == true
                    ? 'healthy'
                    : 'unavailable',
            'authenticated':
                Platform.environment['ANTHROPIC_API_KEY']?.isNotEmpty == true,
          },
        'get_capabilities' || 'getCapabilities' => {
            'capabilities': anthropicPluginManifest['capabilities'],
          },
        'configure_worker' || 'configureWorker' => {'configured': true},
        'start_assignment' => await _execute(worker, request),
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
  AnthropicWorker worker,
  Map<String, dynamic> request,
) async {
  final params = Map<String, Object?>.from(request['params'] as Map);
  final objective = params['objective'];
  final model = params['model'] ?? 'claude-3-5-sonnet-latest';
  if (objective is! String || model is! String || objective.trim().isEmpty) {
    throw const FormatException('objective and model are required');
  }
  final input = params['input'] is Map
      ? Map<String, Object?>.from(params['input'] as Map)
      : const <String, Object?>{};
  final result = await worker.executeStructured(
    apiKey: Platform.environment['ANTHROPIC_API_KEY'],
    model: model,
    prompt: buildAnthropicPrompt(objective, input),
  );
  return {
    'status': 'completed',
    'summary': 'Anthropic worker completed the assignment',
    'output': result.output,
    'evidence': {
      'metrics': {
        'inputTokens': result.usage.inputTokens,
        'outputTokens': result.usage.outputTokens,
      },
    },
  };
}
