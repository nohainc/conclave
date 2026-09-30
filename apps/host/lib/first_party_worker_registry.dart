/// Stable product-to-package mapping for the frozen first-party catalog.
///
/// Provider executable names, environment needs, authentication behavior, and
/// probes are owned by the Worker Packages and do not belong in Workspace.
class FirstPartyWorkerPackage {
  const FirstPartyWorkerPackage._({
    required this.productWorkerTypeId,
    required this.productName,
    required this.packageId,
  });

  final String productWorkerTypeId;
  final String productName;
  final String packageId;

  static const all = <FirstPartyWorkerPackage>[
    FirstPartyWorkerPackage._(
      productWorkerTypeId: 'chatgpt',
      productName: 'ChatGPT',
      packageId: 'codex',
    ),
    FirstPartyWorkerPackage._(
      productWorkerTypeId: 'gemini',
      productName: 'Gemini',
      packageId: 'antigravity',
    ),
  ];

  static FirstPartyWorkerPackage? forProductWorkerTypeId(String id) {
    for (final entry in all) {
      if (entry.productWorkerTypeId == id) return entry;
    }
    return null;
  }

  static FirstPartyWorkerPackage? forPackageId(String id) {
    for (final entry in all) {
      if (entry.packageId == id) return entry;
    }
    return null;
  }

  static FirstPartyWorkerPackage? forProductOrPackageId(String id) =>
      forProductWorkerTypeId(id) ?? forPackageId(id);

  /// Converts persisted pre-v1 package IDs to stable product IDs.
  static String canonicalProductWorkerTypeId(String id) =>
      forPackageId(id)?.productWorkerTypeId ?? id;

  /// Resolves a package ID; non-catalog values pass through for compatibility
  /// with retained non-v1 local records.
  static String packageIdFor(String productWorkerTypeId) =>
      forProductWorkerTypeId(productWorkerTypeId)?.packageId ??
      productWorkerTypeId;

  static String productNameFor(String productWorkerTypeId) =>
      forProductOrPackageId(productWorkerTypeId)?.productName ??
      productWorkerTypeId;
}
