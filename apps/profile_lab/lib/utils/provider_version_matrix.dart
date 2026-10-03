import 'dart:io';

/// Entry representing a single physical version test event recorded on a local host or CI runner.
class TestedVersionEntry {
  const TestedVersionEntry({
    required this.version,
    required this.result, // 'pass' or 'fail'
    required this.recordedAt,
    required this.osVersion,
    required this.testType,
  });

  final String version;
  final String result;
  final String recordedAt;
  final String osVersion;
  final String testType;
}

/// Reusable Provider-Version Test Matrix that strictly separates
/// declared version support ranges from physical test evidence.
class ProviderVersionMatrix {
  const ProviderVersionMatrix({
    required this.providerToolName,
    required this.declaredRanges,
    required this.testedEntries,
  });

  final String providerToolName;
  final List<String> declaredRanges;
  final List<TestedVersionEntry> testedEntries;

  /// Returns unique physically tested versions.
  List<String> get testedVersions =>
      testedEntries.map((e) => e.version).toSet().toList();

  /// Formatted declared range summary string (e.g. "0.180.0 – 0.190.0").
  String get declaredRangeSummary => declaredRanges.isEmpty
      ? 'Unbounded (0.0.1 – 99.0.0)'
      : declaredRanges.join(', ');

  /// Formatted tested versions summary string (e.g. "0.187.2").
  String get testedVersionsSummary => testedVersions.isEmpty
      ? 'None tested locally'
      : testedVersions.join(', ');

  bool get hasTestedVersions => testedVersions.isNotEmpty;

  /// Clear, explicit distinction message reinforcing Supported != Tested.
  String get distinctionNotice =>
      'Declared support: $declaredRangeSummary; Physically tested locally: $testedVersionsSummary. Note: Supported != Tested.';

  /// Computes matrix from candidate Tool Profile map and local/cloud evidence records.
  factory ProviderVersionMatrix.fromProfileAndEvidence({
    required Map<String, Object?> profile,
    required List<Map<String, Object?>> evidenceList,
  }) {
    final providerTool = profile['providerTool'] as Map<String, Object?>? ?? {};
    final toolName = providerTool['name'] as String? ?? 'unknown';

    final ranges = <String>[];
    final supportedList =
        (providerTool['supportedVersions'] as List?)?.cast<Map>() ?? [];
    for (final bound in supportedList) {
      final min = bound['min'] as String? ?? '0.0.0';
      final maxEx = bound['maxExclusive'] as String? ?? '∞';
      ranges.add('$min – $maxEx');
    }

    final testedEntries = <TestedVersionEntry>[];
    for (final ev in evidenceList) {
      final cliVer = ev['providerCliVersion'] as String?;
      if (cliVer != null && cliVer.isNotEmpty && cliVer != 'unknown') {
        testedEntries.add(TestedVersionEntry(
          version: cliVer,
          result: ev['normalizedResult'] as String? ?? 'fail',
          recordedAt:
              ev['recordedAt'] as String? ?? ev['startedAt'] as String? ?? '',
          osVersion:
              ev['osVersion'] as String? ?? Platform.operatingSystemVersion,
          testType: ev['testType'] as String? ?? 'local_test',
        ));
      }
    }

    return ProviderVersionMatrix(
      providerToolName: toolName,
      declaredRanges: ranges,
      testedEntries: testedEntries,
    );
  }
}
