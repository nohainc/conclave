import 'dart:io';

import 'package:conclave_openai_plugin/openai_worker.dart';
import 'package:test/test.dart';

void main() {
  test('rejects missing credentials', () {
    final worker = OpenAiWorker((_, __, ___) async =>
        const ProviderResponse(statusCode: 200, body: 'ok'));
    expect(() => worker.execute(apiKey: null, model: 'gpt', prompt: 'hi'),
        throwsStateError);
  });

  test('reports success usage and retries rate limits', () async {
    final worker = OpenAiWorker((_, __, ___) async => const ProviderResponse(
        statusCode: 200, body: 'ok', inputTokens: 3, outputTokens: 2));
    final response =
        await worker.execute(apiKey: 'secret', model: 'gpt', prompt: 'hi');
    expect(response.outputTokens, 2);
    final limited = OpenAiWorker((_, __, ___) async =>
        const ProviderResponse(statusCode: 429, body: 'busy'));
    expect(() => limited.execute(apiKey: 'secret', model: 'gpt', prompt: 'hi'),
        throwsA(isA<RetriableProviderError>()));
  });

  test('parses structured provider content and preserves usage', () async {
    final worker = OpenAiWorker((_, __, ___) async => const ProviderResponse(
          statusCode: 200,
          body: '{"choices":[{"message":{"content":"{\\"ok\\":true}"}}]}',
          inputTokens: 8,
          outputTokens: 5,
        ));
    final result = await worker.executeStructured(
        apiKey: 'secret', model: 'gpt', prompt: 'hi');
    expect(result.output['ok'], isTrue);
    expect(result.usage.inputTokens, 8);
  });

  test('rejects malformed structured content', () async {
    final worker = OpenAiWorker((_, __, ___) async => const ProviderResponse(
        statusCode: 200,
        body: '{"choices":[{"message":{"content":"plain text"}}]}'));
    expect(
      () => worker.executeStructured(
          apiKey: 'secret', model: 'gpt', prompt: 'hi'),
      throwsFormatException,
    );
  });

  test('bounds provider response bodies', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) {
      request.response
        ..headers.contentType = ContentType.json
        ..write(List.filled(2048, 'x').join());
      request.response.close();
    });
    try {
      await expectLater(
        invokeOpenAi(
          'secret',
          'gpt',
          'hi',
          endpoint:
              Uri.http('127.0.0.1:${server.port}', '/v1/chat/completions'),
          maxResponseBytes: 1024,
        ),
        throwsA(predicate((error) =>
            error.toString().contains('OpenAI response exceeded 1024 bytes'))),
      );
    } finally {
      await subscription.cancel();
      await server.close(force: true);
    }
  });
}
