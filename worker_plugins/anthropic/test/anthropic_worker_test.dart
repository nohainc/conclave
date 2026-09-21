import 'package:conclave_anthropic_plugin/anthropic_worker.dart';
import 'package:test/test.dart';

void main() {
  test('rejects missing credentials and returns successful usage', () async {
    final worker = AnthropicWorker((_, __, ___) async => const ProviderResponse(
        statusCode: 200, body: 'ok', inputTokens: 5, outputTokens: 4));
    expect(() => worker.execute(apiKey: '', model: 'claude', prompt: 'hi'),
        throwsStateError);
    final result =
        await worker.execute(apiKey: 'secret', model: 'claude', prompt: 'hi');
    expect(result.inputTokens, 5);
  });

  test('classifies server failures as retriable', () {
    final worker = AnthropicWorker((_, __, ___) async =>
        const ProviderResponse(statusCode: 503, body: 'busy'));
    expect(
        () => worker.execute(apiKey: 'secret', model: 'claude', prompt: 'hi'),
        throwsA(isA<RetriableProviderError>()));
  });

  test('parses structured content and usage', () async {
    final worker = AnthropicWorker((_, __, ___) async => const ProviderResponse(
          statusCode: 200,
          body: '{"content":[{"type":"text","text":"{\\"ok\\":true}"}]}',
          inputTokens: 7,
          outputTokens: 6,
        ));
    final result = await worker.executeStructured(
        apiKey: 'secret', model: 'claude', prompt: 'hi');
    expect(result.output['ok'], isTrue);
    expect(result.usage.outputTokens, 6);
  });

  test('rejects malformed structured content', () async {
    final worker = AnthropicWorker((_, __, ___) async => const ProviderResponse(
        statusCode: 200, body: '{"content":[{"type":"text","text":"plain"}]}'));
    expect(
      () => worker.executeStructured(
          apiKey: 'secret', model: 'claude', prompt: 'hi'),
      throwsFormatException,
    );
  });
}
