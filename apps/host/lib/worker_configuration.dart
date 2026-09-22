import 'dart:convert';
import 'dart:io';

class WorkerConfigurationStore {
  WorkerConfigurationStore(
    this.root, {
    required this.workspaceId,
    required this.hostId,
  });

  final Directory root;
  final String workspaceId;
  final String hostId;

  File get _file => File('${root.path}/desired-workers.json');

  Future<List<Map<String, Object?>>> read() async {
    if (!await _file.exists()) return [];
    final decoded = jsonDecode(await _file.readAsString());
    if (decoded is! List) {
      throw StateError('desired Worker configuration is malformed');
    }
    return decoded
        .whereType<Map>()
        .map((item) => Map<String, Object?>.from(item))
        .toList();
  }

  Future<List<String>> reconcile(
    Iterable<Map<String, Object?>> desired,
  ) async {
    final normalized = desired.map(_validate).toList();
    await root.create(recursive: true);
    final temporary = File(
      '${_file.path}.tmp-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await temporary.writeAsString(jsonEncode(normalized), flush: true);
      await temporary.rename(_file.path);
    } catch (_) {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
    return normalized
        .where((worker) => worker['enabled'] == true)
        .map((worker) => worker['workerId'] as String)
        .toList()
      ..sort();
  }

  Map<String, Object?> _validate(Map<String, Object?> raw) {
    final workerId = _requiredString(raw, 'workerId');
    final itemWorkspaceId = _requiredString(raw, 'workspaceId');
    final itemHostId = _requiredString(raw, 'hostId');
    if (itemWorkspaceId != workspaceId || itemHostId != hostId) {
      throw StateError('desired Worker belongs to another Host or workspace');
    }
    final pluginId = _requiredString(raw, 'pluginId');
    final roles = _requiredStrings(raw, 'roles');
    final capabilities = _requiredStrings(raw, 'capabilities');
    final config = raw['config'];
    final secretRefs = raw['secretRefs'];
    final enabled = raw['enabled'];
    final concurrencyLimit = raw['concurrencyLimit'];
    if (config is! Map ||
        secretRefs is! List ||
        secretRefs.any((value) => value is! String) ||
        enabled is! bool ||
        concurrencyLimit is! int ||
        concurrencyLimit < 1) {
      throw StateError('desired Worker configuration is invalid');
    }
    return {
      'workerId': workerId,
      'workspaceId': itemWorkspaceId,
      'hostId': itemHostId,
      'pluginId': pluginId,
      'pluginVersionPolicy': _requiredString(raw, 'pluginVersionPolicy'),
      'name': _requiredString(raw, 'name'),
      'roles': roles,
      'capabilities': capabilities,
      'config': Map<String, Object?>.from(config),
      'secretRefs': secretRefs.cast<String>(),
      'enabled': enabled,
      'availability': raw['availability'] ?? 'available',
      'billingMode': _requiredString(raw, 'billingMode'),
      'costMetadata': raw['costMetadata'] is Map
          ? Map<String, Object?>.from(raw['costMetadata'] as Map)
          : <String, Object?>{},
      'independenceKey': _requiredString(raw, 'independenceKey'),
      'concurrencyLimit': concurrencyLimit,
      'sessionPolicy': raw['sessionPolicy'] ?? 'stateless',
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    };
  }

  String _requiredString(Map<String, Object?> raw, String field) {
    final value = raw[field];
    if (value is! String || value.trim().isEmpty) {
      throw StateError('desired Worker field $field is required');
    }
    return value;
  }

  List<String> _requiredStrings(Map<String, Object?> raw, String field) {
    final value = raw[field];
    if (value is! List ||
        value.isEmpty ||
        value.any((item) => item is! String || item.trim().isEmpty)) {
      throw StateError('desired Worker field $field is invalid');
    }
    return value.cast<String>();
  }
}
