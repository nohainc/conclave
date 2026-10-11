import 'dart:convert';
import 'package:crypto/crypto.dart';

/// Bounded public metadata. No provider commands, credentials or paths.
final class DiscoveredModel {
  DiscoveredModel({
    required this.id,
    required this.name,
    this.status = 'listed',
    String? nativeId,
    this.selectionMode = 'separate',
    Iterable<String> supportedReasoningEfforts = const [],
    this.defaultReasoningEffort,
    Map<String, String> variantStatuses = const {},
  })  : variantStatuses = Map.unmodifiable(variantStatuses),
        nativeId = nativeId ?? id,
        supportedReasoningEfforts = List.unmodifiable(
          supportedReasoningEfforts,
        ) {
    final efforts = supportedReasoningEfforts;
    if (variantStatuses.length > 16 ||
        variantStatuses.keys.any((e) =>
            !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$').hasMatch(e)) ||
        variantStatuses.values.any(
            (s) => !const {'listed', 'verified', 'unavailable'}.contains(s)))
      throw const FormatException('Invalid variant status');
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(id) ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$')
            .hasMatch(this.nativeId) ||
        !const {'separate', 'combined'}.contains(selectionMode) ||
        name.isEmpty ||
        name.length > 256 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(name) ||
        !const {'listed', 'verified', 'unavailable'}.contains(status) ||
        efforts.length > 16 ||
        efforts.toSet().length != efforts.length ||
        efforts.any((effort) =>
            !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$').hasMatch(effort)) ||
        (defaultReasoningEffort != null &&
            !efforts.contains(defaultReasoningEffort))) {
      throw const FormatException('Invalid discovered model');
    }
  }
  final String id;
  final String name;

  /// Local execution identity; stripped from Cloud inventory.
  final String nativeId;
  final String selectionMode;
  final String status;
  final List<String> supportedReasoningEfforts;
  final String? defaultReasoningEffort;
  final Map<String, String> variantStatuses;
  Map<String, Object?> toJson(
          {int schemaVersion = 1, bool includeNativeId = true}) =>
      {
        'id': id,
        'name': name,
        'status': status,
        if (schemaVersion == 2) ...{
          if (includeNativeId) 'nativeId': nativeId,
          if (includeNativeId && variantStatuses.isNotEmpty)
            'variantStatuses': {
              for (final e in variantStatuses.keys.toList()..sort())
                e: variantStatuses[e]
            },
          'selectionMode': selectionMode,
          'efforts': supportedReasoningEfforts,
          'defaultEffort': defaultReasoningEffort,
        } else ...{
          if (supportedReasoningEfforts.isNotEmpty)
            'supportedReasoningEfforts': supportedReasoningEfforts,
          if (defaultReasoningEffort != null)
            'defaultReasoningEffort': defaultReasoningEffort,
        },
      };
  factory DiscoveredModel.fromJson(Map<String, Object?> value,
      {int schemaVersion = 1}) {
    if (schemaVersion == 2) {
      if (value.keys.any((key) => !const {
                'id',
                'name',
                'status',
                'nativeId',
                'variantStatuses',
                'selectionMode',
                'efforts',
                'defaultEffort'
              }.contains(key)) ||
          value['selectionMode'] is! String ||
          (value['nativeId'] != null && value['nativeId'] is! String) ||
          (value['defaultEffort'] != null &&
              value['defaultEffort'] is! String) ||
          (value['efforts'] != null &&
              (value['efforts'] is! List ||
                  (value['efforts'] as List).any((e) => e is! String)))) {
        throw const FormatException('Invalid discovered model v2');
      }
      final legacy = <String, Object?>{
        'id': value['id'],
        'name': value['name'],
        'status': value['status'],
        'supportedReasoningEfforts': value['efforts'] ?? const [],
        'defaultReasoningEffort': value['defaultEffort']
      };
      final parsed = DiscoveredModel.fromJson(legacy);
      return DiscoveredModel(
          id: parsed.id,
          name: parsed.name,
          status: parsed.status,
          nativeId: value['nativeId'] as String?,
          variantStatuses: Map<String, String>.from(
              value['variantStatuses'] as Map? ?? const {}),
          selectionMode: value['selectionMode'] as String,
          supportedReasoningEfforts: parsed.supportedReasoningEfforts,
          defaultReasoningEffort: parsed.defaultReasoningEffort);
    }
    if (value.keys.any((k) => !const {
              'id',
              'name',
              'status',
              'supportedReasoningEfforts',
              'defaultReasoningEffort'
            }.contains(k)) ||
        value['id'] is! String ||
        value['name'] is! String ||
        value['status'] is! String ||
        (value['supportedReasoningEfforts'] != null &&
            (value['supportedReasoningEfforts'] is! List ||
                (value['supportedReasoningEfforts'] as List)
                    .any((effort) => effort is! String))) ||
        (value['defaultReasoningEffort'] != null &&
            value['defaultReasoningEffort'] is! String)) {
      throw const FormatException('Invalid discovered model');
    }
    return DiscoveredModel(
        id: value['id'] as String,
        name: value['name'] as String,
        status: value['status'] as String,
        supportedReasoningEfforts:
            ((value['supportedReasoningEfforts'] as List?) ?? const [])
                .cast<String>(),
        defaultReasoningEffort: value['defaultReasoningEffort'] as String?);
  }
}

final class DiscoveredModelCatalog {
  DiscoveredModelCatalog(
      {this.schemaVersion = 1,
      this.stale = false,
      required this.profileDigest,
      required this.providerToolVersion,
      required this.discoveredAt,
      required Iterable<DiscoveredModel> models})
      : models = List.unmodifiable(models) {
    if (!const {1, 2}.contains(schemaVersion) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(profileDigest) ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9.+_-]{0,127}$')
            .hasMatch(providerToolVersion) ||
        discoveredAt.length > 40 ||
        !discoveredAt.contains('T') ||
        !discoveredAt.endsWith('Z') ||
        DateTime.tryParse(discoveredAt) == null ||
        this.models.length > 128 ||
        this.models.map((m) => m.id).toSet().length != this.models.length) {
      throw const FormatException('Invalid discovered model catalog');
    }
  }
  final int schemaVersion;
  final bool stale;

  DiscoveredModelCatalog withStale(bool value) => DiscoveredModelCatalog(
      schemaVersion: value ? 2 : schemaVersion,
      stale: value,
      profileDigest: profileDigest,
      providerToolVersion: providerToolVersion,
      discoveredAt: discoveredAt,
      models: models);

  /// Identity excludes refresh time; includes selection metadata and execution binding.
  String get catalogRevision {
    final entries = models.toList()..sort((a, b) => a.id.compareTo(b.id));
    return sha256
        .convert(utf8.encode(jsonEncode({
          'profileDigest': profileDigest,
          'providerToolVersion': providerToolVersion,
          'models': entries.map((m) => m.toJson(schemaVersion: 2)).toList(),
        })))
        .toString();
  }

  final String profileDigest;
  final String providerToolVersion;
  final String discoveredAt;
  final List<DiscoveredModel> models;
  Map<String, Object?> toJson({bool includeNativeIds = true}) => {
        'schemaVersion': schemaVersion,
        if (schemaVersion == 2 && stale) 'stale': true,
        if (schemaVersion == 2) 'catalogRevision': catalogRevision,
        'profileDigest': profileDigest,
        'providerToolVersion': providerToolVersion,
        'discoveredAt': discoveredAt,
        'models': models
            .map((m) => m.toJson(
                schemaVersion: schemaVersion,
                includeNativeId: includeNativeIds))
            .toList()
      };
  factory DiscoveredModelCatalog.fromJson(Map<String, Object?> value) {
    if (value.keys.any((k) => !const {
              'schemaVersion',
              'stale',
              'catalogRevision',
              'profileDigest',
              'providerToolVersion',
              'discoveredAt',
              'models'
            }.contains(k)) ||
        !const {1, 2}.contains(value['schemaVersion']) ||
        (value['stale'] != null &&
            (value['schemaVersion'] != 2 || value['stale'] is! bool)) ||
        (value['schemaVersion'] == 2 &&
            (value['catalogRevision'] is! String ||
                !RegExp(r'^[0-9a-f]{64}$')
                    .hasMatch(value['catalogRevision'] as String))) ||
        value['profileDigest'] is! String ||
        value['providerToolVersion'] is! String ||
        value['discoveredAt'] is! String ||
        value['models'] is! List)
      throw const FormatException('Invalid model catalog');
    final catalog = DiscoveredModelCatalog(
        schemaVersion: value['schemaVersion'] as int,
        stale: value['stale'] == true,
        profileDigest: value['profileDigest'] as String,
        providerToolVersion: value['providerToolVersion'] as String,
        discoveredAt: value['discoveredAt'] as String,
        models: (value['models'] as List).map((v) => DiscoveredModel.fromJson(
            Map<String, Object?>.from(v as Map),
            schemaVersion: value['schemaVersion'] as int)));
    // Inventory omits native IDs; the revision is an opaque binding there.
    if (catalog.schemaVersion == 2 &&
        (value['models'] as List)
            .every((m) => m is Map && m.containsKey('nativeId')) &&
        value['catalogRevision'] != catalog.catalogRevision) {
      throw const FormatException('Model catalog revision mismatch');
    }
    return catalog;
  }
}
