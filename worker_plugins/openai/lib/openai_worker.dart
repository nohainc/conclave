class ProviderResponse {
  const ProviderResponse(
      {required this.statusCode,
      required this.body,
      this.inputTokens = 0,
      this.outputTokens = 0});
  final int statusCode;
  final String body;
  final int inputTokens;
  final int outputTokens;
}

typedef ProviderInvoker = Future<ProviderResponse> Function(
    String apiKey, String model, String prompt);

class OpenAiWorker {
  OpenAiWorker(this._invoke);
  final ProviderInvoker _invoke;

  Future<ProviderResponse> execute(
      {required String? apiKey,
      required String model,
      required String prompt}) async {
    if (apiKey == null || apiKey.isEmpty)
      throw StateError('OpenAI credential is unavailable');
    final response = await _invoke(apiKey, model, prompt);
    if (response.statusCode == 429 || response.statusCode >= 500) {
      throw RetriableProviderError('OpenAI request is temporarily unavailable');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('OpenAI request failed with ${response.statusCode}');
    }
    return response;
  }
}

class RetriableProviderError implements Exception {
  const RetriableProviderError(this.message);
  final String message;
  @override
  String toString() => message;
}
