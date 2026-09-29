/// Inclusive version bounds enforced by the Workspace CLI probe.
///
/// A null bound means that the v1 catalog reports the installed version but
/// does not reject it on that bound.
class SupportedCliVersionRange {
  const SupportedCliVersionRange({this.minimum, this.maximum});

  final String? minimum;
  final String? maximum;
}

/// Provider CLI checks selected from the first-party Worker descriptor.
class FirstPartyWorkerProbeStrategy {
  const FirstPartyWorkerProbeStrategy({
    required this.id,
    required this.versionArguments,
    required this.authenticationArguments,
    this.authenticationTimeout = const Duration(seconds: 20),
    this.setupExecutionTestPrompt,
  });

  final String id;
  final List<String> versionArguments;
  final List<String> authenticationArguments;
  final Duration authenticationTimeout;
  final String? setupExecutionTestPrompt;
}

/// The single Workspace-owned source for product-to-adapter configuration.
///
/// Provider-specific package implementation details stay here in Conclave
/// Workspace; Cloud and AX use product Worker Type IDs and names only.
class FirstPartyWorkerAdapterDescriptor {
  const FirstPartyWorkerAdapterDescriptor._({
    required this.productWorkerTypeId,
    required this.productName,
    required this.adapterPackageId,
    required this.executableCandidates,
    required this.supportedCliVersionRange,
    required this.requiredLocalPermissions,
    required this.defaultLocalConcurrency,
    required this.probeStrategy,
    required this.cliDisplayName,
    required this.description,
    required this.authStrategy,
  }) : assert(defaultLocalConcurrency > 0);

  final String productWorkerTypeId;
  final String productName;
  final String adapterPackageId;
  final List<String> executableCandidates;
  final SupportedCliVersionRange supportedCliVersionRange;
  final List<String> requiredLocalPermissions;
  final int defaultLocalConcurrency;
  final FirstPartyWorkerProbeStrategy probeStrategy;
  final String cliDisplayName;
  final String description;
  final String authStrategy;

  static const all = <FirstPartyWorkerAdapterDescriptor>[
    FirstPartyWorkerAdapterDescriptor._(
      productWorkerTypeId: 'chatgpt',
      productName: 'ChatGPT',
      adapterPackageId: 'codex',
      executableCandidates: ['codex'],
      supportedCliVersionRange: SupportedCliVersionRange(),
      requiredLocalPermissions: ['workstream_filesystem', 'shell_execution'],
      defaultLocalConcurrency: 1,
      probeStrategy: FirstPartyWorkerProbeStrategy(
        id: 'codex_login_status',
        versionArguments: ['--version'],
        authenticationArguments: ['login', 'status'],
        setupExecutionTestPrompt:
            'Reply with exactly the word OK. Do not use tools.',
      ),
      cliDisplayName: 'Codex CLI',
      description: 'Use ChatGPT through the Codex CLI on this computer.',
      authStrategy: 'browser_auth',
    ),
    FirstPartyWorkerAdapterDescriptor._(
      productWorkerTypeId: 'gemini',
      productName: 'Gemini',
      adapterPackageId: 'antigravity',
      executableCandidates: ['agy'],
      supportedCliVersionRange: SupportedCliVersionRange(),
      requiredLocalPermissions: ['workstream_filesystem', 'shell_execution'],
      defaultLocalConcurrency: 1,
      probeStrategy: FirstPartyWorkerProbeStrategy(
        id: 'antigravity_headless_execution',
        versionArguments: ['--version'],
        // Antigravity has no documented non-interactive auth-status command.
        // Verify cached auth with this tiny request only during setup/manual
        // tests, never during routine readiness polling.
        authenticationArguments: [],
        setupExecutionTestPrompt:
            'Reply with exactly the word OK. Do not use tools.',
      ),
      cliDisplayName: 'Antigravity CLI',
      description: 'Use Gemini through the Antigravity CLI on this computer.',
      authStrategy: 'browser_auth',
    ),
  ];

  static FirstPartyWorkerAdapterDescriptor? forProductWorkerTypeId(String id) {
    for (final descriptor in all) {
      if (descriptor.productWorkerTypeId == id) return descriptor;
    }
    return null;
  }

  static FirstPartyWorkerAdapterDescriptor? forAdapterPackageId(String id) {
    for (final descriptor in all) {
      if (descriptor.adapterPackageId == id) return descriptor;
    }
    return null;
  }

  static FirstPartyWorkerAdapterDescriptor? forProductOrAdapterId(String id) =>
      forProductWorkerTypeId(id) ?? forAdapterPackageId(id);

  /// Converts persisted pre-v1 adapter IDs to their stable product IDs.
  static String canonicalProductWorkerTypeId(String id) =>
      forAdapterPackageId(id)?.productWorkerTypeId ?? id;

  /// Resolves the package used by a product Worker Type; non-catalog IDs pass
  /// through for compatibility with retained non-v1 local records.
  static String adapterPackageIdFor(String productWorkerTypeId) =>
      forProductWorkerTypeId(productWorkerTypeId)?.adapterPackageId ??
      productWorkerTypeId;

  static String productNameFor(String productWorkerTypeId) =>
      forProductOrAdapterId(productWorkerTypeId)?.productName ??
      productWorkerTypeId;
}
