import 'package:conclave_cli_worker_runtime/conclave_cli_worker_runtime.dart';
import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('SafeProviderDiagnostics', () {
    test('safeToken sanitizes invalid characters and caps length', () {
      expect(
        SafeProviderDiagnostics.safeToken('normal-token.123'),
        'normal-token.123',
      );
      expect(
        SafeProviderDiagnostics.safeToken('secret/path with spaces;rm -rf /'),
        'secret_path_with_spaces_rm_-rf__',
      );
      expect(
        SafeProviderDiagnostics.safeToken('a' * 100, maxLength: 10),
        'a' * 10,
      );
    });

    test('safeLevel normalizes levels to valid set', () {
      expect(SafeProviderDiagnostics.safeLevel('INFO'), 'info');
      expect(SafeProviderDiagnostics.safeLevel('DEBUG'), 'debug');
      expect(SafeProviderDiagnostics.safeLevel('error'), 'error');
      expect(SafeProviderDiagnostics.safeLevel('UNKNOWN_CUSTOM_LEVEL'), 'info');
    });

    test('safeEvent validates event name pattern', () {
      expect(
        SafeProviderDiagnostics.safeEvent('worker.init.start'),
        'worker.init.start',
      );
      expect(
        SafeProviderDiagnostics.safeEvent('malicious event with spaces;'),
        'worker.log.invalid_event',
      );
    });

    test('parseStderrLine strips sensitive keys and parses valid JSON', () {
      const line =
          '{"event":"probe.ok","level":"info","context":{"apiKey":"secret-key-123","token":"jwt.token","durationMs":45,"model":"gpt-4"}}';
      final parsed = SafeProviderDiagnostics.parseStderrLine(line);
      expect(parsed['event'], 'worker.probe.ok');
      expect(parsed['level'], 'info');

      final context = parsed['context'] as Map<String, Object?>;
      expect(context.containsKey('apiKey'), isFalse);
      expect(context.containsKey('token'), isFalse);
      expect(context['durationMs'], 45);
      expect(context['model'], 'gpt-4');
    });

    test(
      'parseStderrLine handles non-JSON lines safely without leaking content',
      () {
        const rawSecret =
            'Error: API key sk-proj-1234567890abcdef is expired at /Users/john/secret.txt';
        final parsed = SafeProviderDiagnostics.parseStderrLine(rawSecret);
        expect(parsed['event'], 'worker.stderr.unstructured');
        expect(parsed['level'], 'warn');
        final context = parsed['context'] as Map<String, Object?>;
        expect(context.containsKey('lineBytes'), isTrue);
        // Raw string is not present in context
        expect(context.toString().contains('sk-proj'), isFalse);
      },
    );

    test('redact strips bearer tokens and api keys', () {
      const text =
          'Bearer eyJhbGciOiJIUzI1NiJ9.test and api_key: sk-secret-12345';
      final redacted = SafeProviderDiagnostics.redact(text);
      expect(redacted, 'Bearer [REDACTED] and api_key: [REDACTED]');
    });

    test(
      'normalizeIssueCode maps error strings to stable WorkerIssueCodes',
      () {
        expect(
          SafeProviderDiagnostics.normalizeIssueCode(
            Exception('probe timeout exceeded'),
          ),
          WorkerIssueCode.deadlineExceeded,
        );
        expect(
          SafeProviderDiagnostics.normalizeIssueCode(
            Exception('executable not found in PATH'),
          ),
          WorkerIssueCode.providerToolUnavailable,
        );
        expect(
          SafeProviderDiagnostics.normalizeIssueCode(
            Exception('unauthorized: invalid token'),
          ),
          WorkerIssueCode.providerAuthenticationRequired,
        );
        expect(
          SafeProviderDiagnostics.normalizeIssueCode(
            const FormatException('bad frame'),
          ),
          WorkerIssueCode.malformedFrame,
        );
      },
    );
  });
}
