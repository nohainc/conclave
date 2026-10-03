import 'dart:convert';

import 'package:crypto/crypto.dart';

export 'src/tool_profile_release.dart';
export 'src/worker_trust_policy.dart';
export 'src/tool_profile_verifier.dart';
export 'src/tool_profile_resolution.dart';
export 'src/draft_profile_store.dart';

const maxProfileBytes = 256 * 1024;
const _topLevelKeys = {
  'schemaVersion',
  'profileDefinitionId',
  'releaseVersion',
  'logicalWorkerTypeId',
  'engineFamily',
  'engineCompatibility',
  'providerTool',
  'environment',
  'probe',
  'execution',
  'session',
  'model',
  'timeout',
  'sandbox',
  'progress',
  'errors',
  'capabilities',
  'compatibilityOverrides',
};

class EngineProfile {
  EngineProfile._({
    required this.payloadBytes,
    required this.digest,
    required this.json,
  });

  final List<int> payloadBytes;
  final String digest;
  final Map<String, Object?> json;

  String get definitionId => _text(json, 'profileDefinitionId');
  int get releaseVersion => _integer(json, 'releaseVersion');
  String get workerTypeId => _text(json, 'logicalWorkerTypeId');
  int get schemaVersion => _integer(json, 'schemaVersion');
  List<String> get capabilities =>
      _strings(json['capabilities'], 'capabilities');
  Map<String, Object?> get providerTool =>
      _object(json['providerTool'], 'providerTool');
  Map<String, Object?> get environment =>
      _object(json['environment'], 'environment');
  Map<String, Object?> get execution => _object(json['execution'], 'execution');
  Map<String, Object?> get session => _object(json['session'], 'session');
  Map<String, Object?> get model => _object(json['model'], 'model');
  Map<String, Object?> get timeout => _object(json['timeout'], 'timeout');
  Map<String, Object?> get sandbox => _object(json['sandbox'], 'sandbox');
  Map<String, Object?> get probe => _object(json['probe'], 'probe');

  static EngineProfile parse(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > maxProfileBytes) {
      throw const FormatException('Tool Profile payload is empty or oversized');
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map)
      throw const FormatException('Tool Profile must be a JSON object');
    _validateJsonBounds(decoded);
    final json = Map<String, Object?>.from(decoded);
    final unknown = json.keys.where((key) => !_topLevelKeys.contains(key));
    if (unknown.isNotEmpty)
      throw FormatException('unsupported Tool Profile field: ${unknown.first}');
    if (!json.keys.toSet().containsAll(_topLevelKeys)) {
      throw const FormatException('Tool Profile v1 is missing required fields');
    }
    if (_integer(json, 'schemaVersion') != 1 || json['engineFamily'] != 'cli') {
      throw const FormatException(
        'unsupported Tool Profile schema or engine family',
      );
    }
    _identifier(_text(json, 'profileDefinitionId'), 'profileDefinitionId');
    _identifier(_text(json, 'logicalWorkerTypeId'), 'logicalWorkerTypeId');
    final release = _integer(json, 'releaseVersion');
    if (release < 1 || release > 0x7fffffff)
      throw const FormatException('releaseVersion is out of range');
    final tool = _object(json['providerTool'], 'providerTool');
    _text(tool, 'name');
    final candidates = _strings(
      tool['executableCandidates'],
      'executableCandidates',
    );
    if (candidates.isEmpty ||
        candidates.length > 16 ||
        candidates.any(
          (value) => !RegExp(r'^[A-Za-z0-9._+-]{1,128}$').hasMatch(value),
        )) {
      throw const FormatException('provider executable candidates are invalid');
    }
    final discovery = _object(tool['discovery'], 'providerTool.discovery');
    if (discovery['allowPathSearch'] is! bool) {
      throw const FormatException('provider discovery rules are invalid');
    }
    final locations = _strings(
      discovery['standardLocations'],
      'providerTool.discovery.standardLocations',
    );
    if (locations.length > 16 || locations.any(_unsafeDiscoveryPath)) {
      throw const FormatException('provider discovery locations are invalid');
    }
    final versionProbe = _object(
      tool['versionProbe'],
      'providerTool.versionProbe',
    );
    _expectOnly(
      versionProbe,
      const {'arguments', 'timeoutMs', 'source', 'extract'},
      'providerTool.versionProbe',
    );
    _validateArgumentStrings(
      versionProbe['arguments'],
      'providerTool.versionProbe.arguments',
      max: 32,
    );
    if (versionProbe['timeoutMs'] is! int ||
        (versionProbe['timeoutMs'] as int) < 100 ||
        (versionProbe['timeoutMs'] as int) > 30000 ||
        !const {'stdout', 'stderr'}.contains(versionProbe['source'])) {
      throw const FormatException('provider version probe is invalid');
    }
    final versionExtract = _object(
      versionProbe['extract'],
      'providerTool.versionProbe.extract',
    );
    _expectOnly(
      versionExtract,
      const {'kind', 'patternId'},
      'providerTool.versionProbe.extract',
    );
    if (versionExtract['kind'] != 'regex_capture' ||
        versionExtract['patternId'] != 'semver') {
      throw const FormatException('provider version extraction is invalid');
    }
    final supportedVersions = tool['supportedVersions'];
    if (supportedVersions is! List || supportedVersions.length > 16) {
      throw const FormatException('provider compatibility ranges are invalid');
    }
    for (final value in supportedVersions) {
      if (value is! Map ||
          value.keys
              .toSet()
              .difference(const {'min', 'maxExclusive'}).isNotEmpty ||
          value['min'] is! String ||
          value['maxExclusive'] is! String) {
        throw const FormatException('provider compatibility range is invalid');
      }
      final min = value['min'] as String;
      final max = value['maxExclusive'] as String;
      if (!isSemanticVersion(min) ||
          !isSemanticVersion(max) ||
          compareSemanticVersions(min, max) >= 0) {
        throw const FormatException('provider compatibility range is invalid');
      }
    }
    final execution = _object(json['execution'], 'execution');
    final args = execution['arguments'];
    if (args is! List ||
        args.length > 128 ||
        args.any((item) => !_validArgument(item)))
      throw const FormatException('execution arguments exceed limits');
    final stdin = _object(execution['stdin'], 'execution.stdin');
    if (!const {'raw_text', 'json_object'}.contains(stdin['mode']))
      throw const FormatException('unsupported stdin mode');
    final output = _object(execution['output'], 'execution.output');
    if (!const {'plain_text', 'single_json', 'jsonl'}.contains(output['mode']))
      throw const FormatException('unsupported output mode');
    for (final section in [
      'environment',
      'session',
      'model',
      'timeout',
      'sandbox',
      'probe',
      'errors',
    ]) {
      _object(json[section], section);
    }
    final env = _object(json['environment'], 'environment');
    if (_strings(env['passthrough'], 'environment.passthrough').length > 64) {
      throw const FormatException('too many passthrough environment names');
    }
    final errors = _object(json['errors'], 'errors');
    _boundedArray(errors['mappings'], 'errors.mappings', 64);
    final progress = json['progress'];
    _boundedArray(progress, 'progress', 64);
    _boundedArray(execution['events'], 'execution.events', 128);
    final compatibilityOverrides = json['compatibilityOverrides'];
    _boundedArray(compatibilityOverrides, 'compatibilityOverrides', 16);
    final probe = _object(json['probe'], 'probe');
    _expectOnly(probe, const {'passive', 'live'}, 'probe');
    final passive = _object(probe['passive'], 'probe.passive');
    _expectOnly(passive, const {'checks', 'configChecks'}, 'probe.passive');
    _boundedArray(passive['checks'], 'probe.passive.checks', 16);
    _boundedArray(passive['configChecks'], 'probe.passive.configChecks', 8);
    final live = probe['live'];
    if (live != null) {
      if (live is! Map ||
          live['timeoutMs'] is! int ||
          (live['timeoutMs'] as int) < 100 ||
          (live['timeoutMs'] as int) > 60000) {
        throw const FormatException('probe.live is invalid');
      }
      final liveMap = Map<String, Object?>.from(live);
      _expectOnly(
          liveMap,
          const {
            'timeoutMs',
            'expectedFinalText',
          },
          'probe.live');
      final expected = liveMap['expectedFinalText'];
      if (expected is! Map ||
          expected['kind'] != 'exact' ||
          expected['value'] != 'OK') {
        throw const FormatException('probe live expectation is Engine-owned');
      }
      _expectOnly(
          Map<String, Object?>.from(expected),
          const {
            'kind',
            'value',
          },
          'probe.live.expectedFinalText');
    }
    _validateEnvironmentNames(env);
    _validateRules(
      execution['events'],
      'execution.events',
      128,
      requireActions: true,
    );
    _validateRules(progress, 'progress', 64, requireActions: false);
    _validateErrorRules(errors['mappings']);
    _validateConfigChecks(passive['configChecks']);
    final session = _object(json['session'], 'session');
    _expectOnly(
        session,
        const {
          'supported',
          'formatId',
          'compatibleFormatIds',
          'extract',
          'resumeArguments',
          'requireObservedIdMatch',
        },
        'session');
    if (session['supported'] is! bool ||
        session['requireObservedIdMatch'] is! bool) {
      throw const FormatException('session policy is invalid');
    }
    final sessionFormatId = _text(session, 'formatId');
    if (!_validSessionFormatId(sessionFormatId)) {
      throw const FormatException('session format identity is invalid');
    }
    final compatibleFormats = _strings(
      session['compatibleFormatIds'],
      'session.compatibleFormatIds',
    );
    if (compatibleFormats.isEmpty ||
        compatibleFormats.length > 16 ||
        compatibleFormats.toSet().length != compatibleFormats.length ||
        compatibleFormats.any((format) => !_validSessionFormatId(format)) ||
        !compatibleFormats.contains(sessionFormatId)) {
      throw const FormatException('session format compatibility is invalid');
    }
    _validateSelector(session['extract']);
    _validateArgumentStrings(
      _object(json['session'], 'session')['resumeArguments'],
      'session.resumeArguments',
      max: 32,
    );
    _validateArgumentStrings(
      _object(json['model'], 'model')['arguments'],
      'model.arguments',
      max: 32,
    );
    _validateArgumentStrings(
      _object(json['timeout'], 'timeout')['providerArguments'],
      'timeout.providerArguments',
      max: 16,
    );
    final sandboxMappings = _object(
      _object(json['sandbox'], 'sandbox')['mappings'],
      'sandbox.mappings',
    );
    if (sandboxMappings.keys.any(
      (key) => !const {
        'restricted',
        'provider_default',
        'full_access',
      }.contains(key),
    )) {
      throw const FormatException('unsupported sandbox policy mapping');
    }
    for (final entry in sandboxMappings.entries) {
      _validateArgumentStrings(entry.value, 'sandbox mapping', max: 32);
    }
    final digest = sha256.convert(bytes).toString();
    return EngineProfile._(
      payloadBytes: List.unmodifiable(bytes),
      digest: digest,
      json: json,
    );
  }
}

bool _unsafeDiscoveryPath(String path) {
  if (path.length > 512 || path.contains('\\')) return true;
  if (path.startsWith('{{home}}/')) {
    final parts = path.substring(9).split('/');
    return parts.any((part) => part.isEmpty || part == '.' || part == '..');
  }
  return path != '{{home}}' &&
      !const {
        '/opt/homebrew/bin',
        '/usr/local/bin',
        '/usr/bin',
        '/bin',
      }.contains(path);
}

void _validateArgumentStrings(Object? value, String name, {required int max}) {
  if (value is! List ||
      value.length > max ||
      value.any((item) => item is! String || item.length > 4096)) {
    throw FormatException('$name exceeds Engine limits');
  }
}

bool _validArgument(Object? item) {
  if (item is String) return item.length <= 4096;
  if (item is! Map || item.length > 3) return false;
  const allowed = {
    'sandboxPolicyMapping',
    'modelArguments',
    'sessionResumeArguments',
    'providerTimeoutArguments',
    'ifPresent',
    'ifAbsent',
    'ifSessionPolicy',
    'values',
  };
  return item.keys.every((key) => key is String && allowed.contains(key)) &&
      (!item.containsKey('values') ||
          (item['values'] is List &&
              (item['values'] as List).length <= 32 &&
              (item['values'] as List).every(
                (v) => v is String && v.length <= 4096,
              )));
}

void _validateSelector(Object? value) {
  if (value == null) return;
  if (value is! String ||
      value.length > 256 ||
      !RegExp(r'^\$(?:\.[A-Za-z_][A-Za-z0-9_]*)+$').hasMatch(value) ||
      value.split('.').length - 1 > 16 ||
      value.split('.').any(
            (part) =>
                const {'__proto__', 'prototype', 'constructor'}.contains(part),
          )) {
    throw const FormatException(
      'Profile selector is invalid or exceeds limits',
    );
  }
}

void _validateRules(
  Object? value,
  String name,
  int maxRules, {
  required bool requireActions,
}) {
  if (value is! List || value.length > maxRules) {
    throw FormatException('$name exceeds rule count limit');
  }
  for (final raw in value) {
    if (raw is! Map || raw.length > 8)
      throw FormatException('$name rule is invalid');
    final conditions = raw['when'];
    if (conditions is! List || conditions.length > 16) {
      throw FormatException('$name conditions exceed limit');
    }
    for (final condition in conditions) {
      if (condition is! Map || condition.length > 5)
        throw FormatException('$name condition is invalid');
      _validateSelector(condition['selector']);
      final values = condition['values'];
      if (values is List &&
          (values.length > 32 ||
              values.any((v) => v is String && v.length > 4096))) {
        throw FormatException('$name predicate values exceed limit');
      }
    }
    if (requireActions) {
      final actions = raw['actions'];
      if (actions is! List || actions.length > 16)
        throw FormatException('$name actions exceed limit');
      for (final action in actions) {
        if (action is! Map || action.length > 4)
          throw FormatException('$name action is invalid');
        _validateSelector(action['selector']);
      }
    } else if (raw['percentage'] is! int ||
        (raw['percentage'] as int) < 0 ||
        (raw['percentage'] as int) > 100 ||
        raw['messageKey'] is! String ||
        (raw['messageKey'] as String).length > 128) {
      throw FormatException('$name progress action is invalid');
    }
  }
}

void _validateErrorRules(Object? value) {
  if (value is! List || value.length > 64)
    throw const FormatException('error mappings exceed limit');
  for (final raw in value) {
    if (raw is! Map || raw.length > 4 || raw['evidence'] is! Map)
      throw const FormatException('error mapping is invalid');
    final evidence = raw['evidence'] as Map;
    if (evidence.length > 3 ||
        (evidence['patternId'] is String &&
            (evidence['patternId'] as String).length > 64)) {
      throw const FormatException('error mapping evidence exceeds limits');
    }
  }
}

void _validateConfigChecks(Object? value) {
  if (value is! List || value.length > 8)
    throw const FormatException('config checks exceed limit');
  for (final raw in value) {
    if (raw is! Map || raw.length > 12)
      throw const FormatException('config check is invalid');
    final path = raw['relativePath'];
    final maxBytes = raw['maxBytes'];
    if (raw['root'] != 'home' ||
        path is! String ||
        path.length > 256 ||
        path.startsWith('/') ||
        path.contains('\\') ||
        path
            .split('/')
            .any((part) => part.isEmpty || part == '.' || part == '..') ||
        !RegExp(r'^[A-Za-z0-9._/-]+$').hasMatch(path) ||
        maxBytes is! int ||
        maxBytes < 1 ||
        maxBytes > 64 * 1024) {
      throw const FormatException('unsafe Profile config check path');
    }
    final rules = raw['rules'];
    if (rules is! List || rules.length > 32)
      throw const FormatException('config check rules exceed limit');
    for (final rule in rules) {
      if (rule is! Map || rule.length > 8)
        throw const FormatException('config rule is invalid');
      final conditions = rule['when'];
      if (conditions is! List || conditions.length > 16)
        throw const FormatException('config rule conditions exceed limit');
      for (final condition in conditions) {
        if (condition is! Map || condition.length > 5)
          throw const FormatException('config condition is invalid');
        _validateSelector(condition['selector']);
      }
    }
  }
}

void _expectOnly(Map<String, Object?> value, Set<String> allowed, String path) {
  final unknown = value.keys.where((key) => !allowed.contains(key));
  if (unknown.isNotEmpty) {
    throw FormatException('$path contains unsupported field: ${unknown.first}');
  }
}

void _boundedArray(Object? value, String name, int max) {
  if (value is! List || value.length > max)
    throw FormatException('$name must be a bounded array');
}

void _validateJsonBounds(Object? value, [int depth = 0]) {
  if (depth > 24)
    throw const FormatException('Tool Profile nesting exceeds limit');
  if (value is String && value.length > 4096)
    throw const FormatException('Tool Profile string exceeds limit');
  if (value is List) {
    if (value.length > 128)
      throw const FormatException('Tool Profile array exceeds limit');
    for (final item in value) {
      _validateJsonBounds(item, depth + 1);
    }
  }
  if (value is Map) {
    if (value.length > 128 ||
        value.keys.any((key) => key is! String || key.length > 128)) {
      throw const FormatException('Tool Profile object exceeds limit');
    }
    for (final item in value.values) {
      _validateJsonBounds(item, depth + 1);
    }
  }
}

void _validateEnvironmentNames(Map<String, Object?> environment) {
  final names = _strings(environment['passthrough'], 'environment.passthrough');
  final set = _object(environment['set'], 'environment.set');
  if (names.length + set.length > 64)
    throw const FormatException('too many Profile environment names');
  for (final name in [...names, ...set.keys]) {
    if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,127}$').hasMatch(name) ||
        isReservedEnvironmentName(name)) {
      throw FormatException(
        'reserved or invalid Profile environment name: $name',
      );
    }
  }
}

/// Provider credentials (for example OPENAI_API_KEY) may be passed through
/// when an official Profile explicitly declares them. Machine and Conclave
/// credentials are never available to provider processes.
bool isReservedEnvironmentName(String name) => RegExp(
      r'^(?:CONCLAVE_|CLOUD_|WORKER_|WORKSPACE_|SECRET_STORE_)|^(?:CONCLAVE_API_KEY|CONCLAVE_CLOUD_TOKEN|CLOUD_API_KEY|CLOUD_TOKEN|WORKER_TOKEN|WORKSPACE_TOKEN)$',
      caseSensitive: false,
    ).hasMatch(name);

bool engineVersionCompatible(EngineProfile profile, String version) {
  final range = _object(
    profile.json['engineCompatibility'],
    'engineCompatibility',
  );
  final min = _text(range, 'min');
  final max = _text(range, 'maxExclusive');
  return semanticVersionInRange(version, min, max);
}

/// Compares semantic versions according to SemVer precedence (build metadata
/// does not affect ordering).
int compareSemanticVersions(String left, String right) =>
    _SemanticVersion.parse(left).compareTo(_SemanticVersion.parse(right));

bool isSemanticVersion(String value) {
  try {
    _SemanticVersion.parse(value);
    return true;
  } on FormatException {
    return false;
  }
}

/// Checks the Profile convention of an inclusive minimum and exclusive maximum.
bool semanticVersionInRange(
  String version,
  String minInclusive,
  String maxExclusive,
) =>
    compareSemanticVersions(version, minInclusive) >= 0 &&
    compareSemanticVersions(version, maxExclusive) < 0;

Object? _required(Map<String, Object?> map, String key) {
  if (!map.containsKey(key))
    throw FormatException('missing Tool Profile field: $key');
  return map[key];
}

String _text(Map<String, Object?> map, String key) {
  final value = _required(map, key);
  if (value is! String || value.isEmpty || value.length > 4096)
    throw FormatException('$key must be bounded text');
  return value;
}

int _integer(Map<String, Object?> map, String key) {
  final value = _required(map, key);
  if (value is! int) throw FormatException('$key must be an integer');
  return value;
}

Map<String, Object?> _object(Object? value, String name) {
  if (value is! Map) throw FormatException('$name must be an object');
  return Map<String, Object?>.from(value);
}

List<String> _strings(Object? value, String name) {
  if (value is! List ||
      value.length > 128 ||
      value.any((item) => item is! String)) {
    throw FormatException('$name must be a bounded string array');
  }
  return value.cast<String>();
}

void _identifier(String value, String name) {
  if (!RegExp(r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$').hasMatch(value) ||
      value.length > 96) {
    throw FormatException('$name is not a valid identifier');
  }
}

bool _validSessionFormatId(String value) =>
    value.length <= 96 &&
    RegExp(r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$').hasMatch(value);

class _SemanticVersion implements Comparable<_SemanticVersion> {
  const _SemanticVersion(this.core, this.prerelease);

  final List<String> core;
  final List<String> prerelease;

  static final _pattern = RegExp(
    r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$',
  );

  factory _SemanticVersion.parse(String value) {
    if (value.length > 128) {
      throw const FormatException('semantic version exceeds its limit');
    }
    final match = _pattern.firstMatch(value);
    if (match == null) {
      throw const FormatException('invalid semantic version');
    }
    final prerelease = match.group(4)?.split('.') ?? const <String>[];
    if (prerelease.any(
      (identifier) => RegExp(r'^0[0-9]+$').hasMatch(identifier),
    )) {
      throw const FormatException('invalid semantic version prerelease');
    }
    return _SemanticVersion([
      match.group(1)!,
      match.group(2)!,
      match.group(3)!,
    ], prerelease);
  }

  @override
  int compareTo(_SemanticVersion other) {
    for (var index = 0; index < core.length; index++) {
      final order = _compareNumericIdentifiers(core[index], other.core[index]);
      if (order != 0) return order;
    }
    if (prerelease.isEmpty || other.prerelease.isEmpty) {
      if (prerelease.isEmpty && other.prerelease.isEmpty) return 0;
      return prerelease.isEmpty ? 1 : -1;
    }
    for (var index = 0;
        index < prerelease.length && index < other.prerelease.length;
        index++) {
      final left = prerelease[index];
      final right = other.prerelease[index];
      final leftNumeric = RegExp(r'^[0-9]+$').hasMatch(left);
      final rightNumeric = RegExp(r'^[0-9]+$').hasMatch(right);
      final order = leftNumeric && rightNumeric
          ? _compareNumericIdentifiers(left, right)
          : leftNumeric
              ? -1
              : rightNumeric
                  ? 1
                  : left.compareTo(right);
      if (order != 0) return order;
    }
    return prerelease.length.compareTo(other.prerelease.length);
  }
}

int _compareNumericIdentifiers(String left, String right) {
  if (left.length != right.length) return left.length.compareTo(right.length);
  return left.compareTo(right);
}
