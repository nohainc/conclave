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

Future<ProviderResponse> invokeOpenAi(
    String apiKey, String model, String prompt) async {
  final client = HttpClient();
  try {
    final request = await client
        .postUrl(Uri.parse('https://api.openai.com/v1/chat/completions'));
    request.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer $apiKey')
      ..contentType = ContentType.json;
    request.write(jsonEncode({
      'model': model,
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
