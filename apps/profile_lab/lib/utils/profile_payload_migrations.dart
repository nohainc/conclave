/// Small, explicit migrations for unsigned Profile Lab payloads.
///
/// Published releases remain immutable. These migrations only repair local
/// drafts and newly-created drafts from an older starter so they can be tested
/// and republished with the current Worker Engine contract.
Map<String, Object?>? migrateProfilePayload(
  Map<String, Object?> profile,
) {
  if (profile['profileDefinitionId'] != 'chatgpt-codex' ||
      profile['logicalWorkerTypeId'] != 'chatgpt') {
    return null;
  }

  final modelValue = profile['model'];
  if (modelValue is! Map) return null;
  final discoveryValue = modelValue['discovery'];
  final legacyDiscovery =
      discoveryValue is Map && discoveryValue['format'] == 'tsv';
  final legacyStaticCatalog =
      modelValue.containsKey('catalog') || modelValue.containsKey('allowlist');
  if (!legacyDiscovery && !legacyStaticCatalog) {
    return null;
  }

  final migrated = _deepCopy(profile);
  final model = Map<String, Object?>.from(migrated['model'] as Map);
  model['unknownModelPolicy'] = 'pass_through';
  model.remove('catalog');
  model.remove('allowlist');
  model.remove('defaultReasoningEffort');
  model.remove('supportedReasoningEfforts');
  model['discovery'] = <String, Object?>{
    'schemaVersion': 1,
    'arguments': ['app-server', '--listen', 'stdio://'],
    'timeoutMs': 10000,
    'format': 'codex_app_server',
    'idPrefix': '',
  };
  migrated['model'] = model;
  return migrated;
}

Map<String, Object?> _deepCopy(Map<String, Object?> value) {
  final copy = <String, Object?>{};
  for (final entry in value.entries) {
    final child = entry.value;
    copy[entry.key] = switch (child) {
      Map() => _deepCopy(Map<String, Object?>.from(child)),
      List() => child.map(_deepCopyValue).toList(growable: false),
      _ => child,
    };
  }
  return copy;
}

Object? _deepCopyValue(Object? value) => switch (value) {
      Map() => _deepCopy(Map<String, Object?>.from(value)),
      List() => value.map(_deepCopyValue).toList(growable: false),
      _ => value,
    };
