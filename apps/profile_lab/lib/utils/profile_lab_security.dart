import 'dart:io';

/// Safety & Redaction utilities enforcing Profile Lab execution security boundaries.
class ProfileLabSecurity {
  /// Unsafe executable names and shell interpreters forbidden from declaration in Tool Profiles.
  static const Set<String> forbiddenExecutables = {
    'sh',
    'bash',
    'zsh',
    'fish',
    'csh',
    'ksh',
    'tcsh',
    'sudo',
    'su',
    'eval',
    'exec',
    'rm',
    'del',
    'curl',
    'wget',
    'fetch',
    'nc',
    'netcat',
    'python',
    'python3',
    'perl',
    'ruby',
    'node',
    'php',
  };

  /// Validates whether a declared executable candidate is safe for discovery.
  static bool isUnsafeExecutable(String name) {
    final lower = name.trim().toLowerCase();
    if (lower.isEmpty) return true;

    // Disallow path traversal, absolute paths, or shell injection tokens
    if (lower.contains('/') ||
        lower.contains('\\') ||
        lower.contains('..') ||
        lower.contains(';') ||
        lower.contains('&') ||
        lower.contains('|')) {
      return true;
    }

    return forbiddenExecutables.contains(lower);
  }

  /// Redacts sensitive credentials, Bearer tokens, API keys, and private keys from test logs and diagnostic strings.
  static String redactSecrets(String input) {
    if (input.isEmpty) return input;
    var redacted = input;

    // Redact Bearer & Authorization headers / tokens
    redacted = redacted.replaceAllMapped(
      RegExp(r'(Bearer\s+|token[=:]\s*)[A-Za-z0-9._~\-/+=]+',
          caseSensitive: false),
      (m) => '${m.group(1)}[REDACTED_TOKEN]',
    );

    // Redact API keys (e.g. sk-..., conclave_..., ghp_..., etc.)
    redacted = redacted.replaceAll(
      RegExp(r'\b(sk|conclave|ghp|gho|glpat|xoxb|xoxp)-[A-Za-z0-9_\-]{16,}\b'),
      '[REDACTED_API_KEY]',
    );

    // Redact PEM private key blocks
    redacted = redacted.replaceAll(
      RegExp(
          r'-----BEGIN\s+([A-Z\s]+)?PRIVATE\s+KEY-----[\s\S]*?-----END\s+\1?PRIVATE\s+KEY-----'),
      '[REDACTED_PRIVATE_KEY]',
    );

    // Redact secret env key-value assignments
    redacted = redacted.replaceAllMapped(
      RegExp(
          r'(API_KEY|SECRET|PASSWORD|AUTH_TOKEN|PRIVATE_KEY|DATABASE_URL)=([^\s;&]+)',
          caseSensitive: false),
      (m) => '${m.group(1)}=[REDACTED]',
    );

    return redacted;
  }

  /// Constructs an isolated host environment map stripped of host application secrets.
  static Map<String, String> buildIsolatedEnvironment() {
    final hostEnv = Map<String, String>.from(Platform.environment);
    hostEnv.removeWhere((key, _) {
      final k = key.toUpperCase();
      return k.startsWith('CONCLAVE_SECRET_') ||
          k.contains('SECRET') ||
          k.contains('TOKEN') ||
          k.contains('API_KEY') ||
          k.contains('PRIVATE_KEY') ||
          k.contains('PASSWORD') ||
          k.contains('DATABASE_URL') ||
          k.startsWith('CF_PAGES_') ||
          k.startsWith('WRANGLER_') ||
          k.contains('BETTER_AUTH');
    });
    return hostEnv;
  }
}
