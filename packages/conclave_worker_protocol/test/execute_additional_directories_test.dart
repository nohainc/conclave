import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';
import 'package:test/test.dart';

void main() {
  ExecuteRequest request(List<String> directories) => ExecuteRequest(
      requestId: 'r',
      assignmentId: 'a',
      prompt: 'p',
      timeoutMs: 1000,
      sessionPolicy: WorkerSessionPolicy.stateless,
      additionalDirectories: directories);

  test('round-trips additional folders and omits an empty list', () {
    final frame = request(['/Users/me/api', r'C:\work\docs']);
    expect(ExecuteRequest.fromJson(frame.toJson()).additionalDirectories,
        ['/Users/me/api', r'C:\work\docs']);
    expect(request(const []).toJson().containsKey('additionalDirectories'),
        isFalse);
    expect(
        ExecuteRequest.fromJson(request(const []).toJson())
            .additionalDirectories,
        isEmpty);
  });

  test('rejects relative, duplicate, oversized, and malformed folder lists',
      () {
    expect(() => request(['relative/path']), throwsFormatException);
    expect(() => request(['/a', '/a']), throwsFormatException);
    expect(() => request(['/a\x00b']), throwsFormatException);
    expect(
        () => request([
              for (var i = 0;
                  i <= WorkerProtocolLimits.maxAdditionalDirectories;
                  i++)
                '/folder-$i'
            ]),
        throwsFormatException);
    expect(
        () => ExecuteRequest.fromJson({
              ...request(const []).toJson(),
              'additionalDirectories': [42],
            }),
        throwsFormatException);
  });
}
