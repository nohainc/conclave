import 'dart:convert';
import 'dart:io';

class ProviderResponse {
  const ProviderResponse({
    required this.statusCode,
    required this.body,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.requestId,
    this.retryAfterSeconds,
  });

  final int statusCode;
  final String body;
  final int inputTokens;
  final int outputTokens;
  final String? requestId;
  final int? retryAfterSeconds;
}

class StructuredProviderResult {
  const StructuredProviderResult({required this.output, required this.usage});
  final Map<String, Object?> output;
  final ProviderUsage usage;
}

class ProviderUsage {
  const ProviderUsage({required this.inputTokens, required this.outputTokens});
  final int inputTokens;
  final int outputTokens;
}

typedef ProviderInvoker = Future<ProviderResponse> Function(
    String apiKey, String model, String prompt);

class AnthropicWorker {
  AnthropicWorker(this._invoke);
  final ProviderInvoker _invoke;

  Future<ProviderResponse> execute({
    required String? apiKey,
    required String model,
    required String prompt,
  }) async {
    if (apiKey == null || apiKey.isEmpty) {
      throw StateError('Anthropic credential is unavailable');
    }
    final response = await _invoke(apiKey, model, prompt);
    if (response.statusCode == 429 || response.statusCode >= 500) {
      throw RetriableProviderError(
        'Anthropic request is temporarily unavailable',
        retryAfterSeconds: response.retryAfterSeconds,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Anthropic request failed with ${response.statusCode}');
    }
    return response;
  }

  Future<StructuredProviderResult> executeStructured({
    required String? apiKey,
    required String model,
    required String prompt,
  }) async {
    final response =
        await execute(apiKey: apiKey, model: model, prompt: prompt);
    final decoded = jsonDecode(response.body);
    if (decoded is! Map || decoded['content'] is! List) {
      throw const FormatException('Anthropic response has no content');
    }
    final content = decoded['content'] as List;
    final text = content.isNotEmpty && content.first is Map
        ? (content.first as Map)['text']
        : null;
    final output = _decodeContent(text);
    return StructuredProviderResult(
      output: output,
      usage: ProviderUsage(
        inputTokens: response.inputTokens,
        outputTokens: response.outputTokens,
      ),
    );
  }

  Map<String, Object?> _decodeContent(Object? content) {
    if (content is Map) return Map<String, Object?>.from(content);
    if (content is! String || content.trim().isEmpty) {
      throw const FormatException(
          'Anthropic response has no structured content');
    }
    final decoded = jsonDecode(content);
    if (decoded is! Map) {
      throw const FormatException(
          'Anthropic structured content is not an object');
    }
    return Map<String, Object?>.from(decoded);
  }
}

class RetriableProviderError implements Exception {
  const RetriableProviderError(this.message, {this.retryAfterSeconds});
  final String message;
  final int? retryAfterSeconds;
  @override
  String toString() => message;
}

String buildAnthropicPrompt(
  String objective,
  Map<String, Object?> input, {
  int maxBytes = 128 * 1024,
}) {
  if (maxBytes <= 0) throw ArgumentError.value(maxBytes, 'maxBytes');
  if (input.isEmpty) return objective;
  final prompt = '$objective\n\nConclave task context (JSON):\n${jsonEncode(input)}';
  final bytes = utf8.encode(prompt);
  if (bytes.length <= maxBytes) return prompt;
  return '${utf8.decode(bytes.take(maxBytes).toList(), allowMalformed: true)}\n[context truncated]';
}

Future<ProviderResponse> invokeAnthropic(
  String apiKey,
  String model,
  String prompt, {
  Uri? endpoint,
  Duration timeout = const Duration(seconds: 60),
  int maxResponseBytes = 8 * 1024 * 1024,
}) async {
  if (maxResponseBytes <= 0) {
    throw ArgumentError.value(
        maxResponseBytes, 'maxResponseBytes', 'must be positive');
  }
  final client = HttpClient();
  try {
    client.connectionTimeout = timeout;
    final request = await client
        .postUrl(endpoint ?? Uri.https('api.anthropic.com', '/v1/messages'))
        .timeout(timeout);
    request.headers
      ..set('x-api-key', apiKey)
      ..set('anthropic-version', '2023-06-01')
      ..contentType = ContentType.json;
    request.write(jsonEncode({
      'model': model,
      'max_tokens': 4096,
      'messages': [
        {'role': 'user', 'content': prompt}
      ],
    }));
    final response = await request.close().timeout(timeout);
    final body = await _readBoundedBody(response, maxResponseBytes, timeout);
    final decoded = _decodeMap(body);
    final usage = decoded['usage'] is Map
        ? decoded['usage'] as Map
        : const <Object?, Object?>{};
    return ProviderResponse(
      statusCode: response.statusCode,
      body: body,
      inputTokens: (usage['input_tokens'] as num?)?.toInt() ?? 0,
      outputTokens: (usage['output_tokens'] as num?)?.toInt() ?? 0,
      requestId: response.headers.value('request-id'),
      retryAfterSeconds:
          int.tryParse(response.headers.value('retry-after') ?? ''),
    );
  } finally {
    client.close(force: true);
  }
}

Future<String> _readBoundedBody(
  HttpClientResponse response,
  int maxBytes,
  Duration timeout,
) async {
  final bytes = <int>[];
  await for (final chunk in response.timeout(timeout)) {
    if (bytes.length + chunk.length > maxBytes) {
      throw StateError('Anthropic response exceeded $maxBytes bytes');
    }
    bytes.addAll(chunk);
  }
  return utf8.decode(bytes);
}

Map<String, Object?> _decodeMap(String body) {
  try {
    final decoded = jsonDecode(body);
    return decoded is Map ? Map<String, Object?>.from(decoded) : const {};
  } on FormatException {
    return const {};
  }
}
