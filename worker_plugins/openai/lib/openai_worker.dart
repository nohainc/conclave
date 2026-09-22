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

class OpenAiWorker {
  OpenAiWorker(this._invoke);
  final ProviderInvoker _invoke;

  bool get isReady => true;

  Future<ProviderResponse> execute({
    required String? apiKey,
    required String model,
    required String prompt,
  }) async {
    if (apiKey == null || apiKey.isEmpty) {
      throw StateError('OpenAI credential is unavailable');
    }
    final response = await _invoke(apiKey, model, prompt);
    _throwForStatus(response);
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
    if (decoded is! Map) {
      throw const FormatException('OpenAI response is not an object');
    }
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty || choices.first is! Map) {
      throw const FormatException('OpenAI response has no choices');
    }
    final message = (choices.first as Map)['message'];
    final content = message is Map ? message['content'] : null;
    final output = _decodeContent(content);
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
      throw const FormatException('OpenAI response has no structured content');
    }
    final decoded = jsonDecode(content);
    if (decoded is! Map) {
      throw const FormatException('OpenAI structured content is not an object');
    }
    return Map<String, Object?>.from(decoded);
  }

  void _throwForStatus(ProviderResponse response) {
    if (response.statusCode == 429 || response.statusCode >= 500) {
      throw RetriableProviderError(
        'OpenAI request is temporarily unavailable',
        retryAfterSeconds: response.retryAfterSeconds,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('OpenAI request failed with ${response.statusCode}');
    }
  }
}

class RetriableProviderError implements Exception {
  const RetriableProviderError(this.message, {this.retryAfterSeconds});
  final String message;
  final int? retryAfterSeconds;
  @override
  String toString() => message;
}

String buildOpenAiPrompt(
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

Future<ProviderResponse> invokeOpenAi(
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
        .postUrl(
            endpoint ?? Uri.https('api.openai.com', '/v1/chat/completions'))
        .timeout(timeout);
    request.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer $apiKey')
      ..contentType = ContentType.json;
    request.write(jsonEncode({
      'model': model,
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
      inputTokens: (usage['prompt_tokens'] as num?)?.toInt() ?? 0,
      outputTokens: (usage['completion_tokens'] as num?)?.toInt() ?? 0,
      requestId: response.headers.value('x-request-id'),
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
      throw StateError('OpenAI response exceeded $maxBytes bytes');
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
