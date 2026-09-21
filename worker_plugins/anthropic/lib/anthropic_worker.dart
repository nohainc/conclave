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

Future<ProviderResponse> invokeAnthropic(
    String apiKey, String model, String prompt) async {
  final client = HttpClient();
  try {
    final request = await client
        .postUrl(Uri.parse('https://api.anthropic.com/v1/messages'));
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
    final response = await request.close();
    final body = await utf8.decodeStream(response);
    final decoded = jsonDecode(body);
    final usage = decoded is Map && decoded['usage'] is Map
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
