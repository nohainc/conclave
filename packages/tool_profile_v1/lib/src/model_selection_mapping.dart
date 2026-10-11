import '../tool_profile_v1.dart'
    show isSemanticVersion, semanticVersionInRange, compareSemanticVersions;

/// Finite signed data: no suffix parsing or provider-specific interpretation.
final class NativeModelVariant {
  NativeModelVariant(
      {required this.nativeId,
      required this.effort,
      this.minVersion,
      this.maxVersion});
  final String nativeId;
  final String effort;
  final String? minVersion;
  final String? maxVersion;
  bool supports(String version) =>
      minVersion == null ||
      semanticVersionInRange(version, minVersion!, maxVersion!);
  bool overlaps(NativeModelVariant other) =>
      minVersion == null ||
      other.minVersion == null ||
      (compareSemanticVersions(maxVersion!, other.minVersion!) > 0 &&
          compareSemanticVersions(other.maxVersion!, minVersion!) > 0);
}

final class CombinedModelMapping {
  CombinedModelMapping(
      {required this.id,
      required this.name,
      required this.variants,
      this.defaultEffort});
  final String id;
  final String name;
  final List<NativeModelVariant> variants;
  final String? defaultEffort;
}

List<CombinedModelMapping> parseModelSelectionMapping(Object? raw) {
  if (raw == null) return const [];
  Never fail() => throw const FormatException(
      'Invalid or ambiguous model selection mapping');
  final idPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$');
  final effortPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$');
  if (raw is! Map ||
      raw.keys.any((key) => !const {'schemaVersion', 'models'}.contains(key)) ||
      raw['schemaVersion'] != 1 ||
      raw['models'] is! List ||
      (raw['models'] as List).isEmpty ||
      (raw['models'] as List).length > 128) fail();
  final result = <CombinedModelMapping>[];
  final ids = <String>{};
  final allVariants = <({String modelId, NativeModelVariant variant})>[];
  for (final value in raw['models'] as List) {
    if (value is! Map ||
        value.keys.any((key) =>
            !const {'id', 'name', 'variants', 'defaultEffort'}.contains(key)) ||
        value['id'] is! String ||
        !idPattern.hasMatch(value['id'] as String) ||
        !ids.add(value['id'] as String) ||
        value['name'] is! String ||
        (value['name'] as String).isEmpty ||
        (value['name'] as String).length > 256 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(value['name'] as String) ||
        value['variants'] is! List ||
        (value['variants'] as List).isEmpty ||
        (value['variants'] as List).length > 128) fail();
    final variants = <NativeModelVariant>[];
    for (final entry in value['variants'] as List) {
      if (entry is! Map ||
          entry.keys.any((key) =>
              !const {'nativeId', 'effort', 'providerVersion'}.contains(key)) ||
          entry['nativeId'] is! String ||
          !idPattern.hasMatch(entry['nativeId'] as String) ||
          entry['effort'] is! String ||
          !effortPattern.hasMatch(entry['effort'] as String)) fail();
      final version = entry['providerVersion'];
      if (version != null &&
          (version is! Map ||
              version.keys
                  .any((key) => !const {'min', 'maxExclusive'}.contains(key)) ||
              version['min'] is! String ||
              version['maxExclusive'] is! String ||
              !isSemanticVersion(version['min'] as String) ||
              !isSemanticVersion(version['maxExclusive'] as String) ||
              compareSemanticVersions(version['min'] as String,
                      version['maxExclusive'] as String) >=
                  0)) fail();
      final variant = NativeModelVariant(
          nativeId: entry['nativeId'] as String,
          effort: entry['effort'] as String,
          minVersion: version == null ? null : version['min'] as String,
          maxVersion:
              version == null ? null : version['maxExclusive'] as String);
      for (final prior in allVariants) {
        if (variant.overlaps(prior.variant) &&
            (variant.nativeId == prior.variant.nativeId ||
                (prior.modelId == value['id'] &&
                    variant.effort == prior.variant.effort))) fail();
      }
      allVariants.add((modelId: value['id'] as String, variant: variant));
      if (allVariants.length > 128) fail();
      variants.add(variant);
    }
    if (variants.map((v) => v.effort).toSet().length > 16 ||
        (value['defaultEffort'] != null &&
            (value['defaultEffort'] is! String ||
                !variants.any((v) => v.effort == value['defaultEffort']))))
      fail();
    result.add(CombinedModelMapping(
        id: value['id'] as String,
        name: value['name'] as String,
        variants: List.unmodifiable(variants),
        defaultEffort: value['defaultEffort'] as String?));
  }
  return List.unmodifiable(result);
}
