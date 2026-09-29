import 'dart:typed_data';

/// A signed first-party adapter archive embedded in the Workspace application.
class BundledAdapterPackage {
  const BundledAdapterPackage({
    required this.archiveBytes,
    required this.manifest,
  });

  final Uint8List archiveBytes;
  final Map<String, Object?> manifest;
}
