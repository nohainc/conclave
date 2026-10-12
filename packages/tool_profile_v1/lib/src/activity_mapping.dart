/// Provider-neutral replay of declarative Profile activity mappings.
///
/// This deliberately returns data rather than protocol frames. The Engine,
/// Profile Lab and any other caller can attach their own execution identity
/// while sharing the exact selector and predicate semantics.
class ProfileActivityMappingResult {
  const ProfileActivityMappingResult({
    required this.type,
    required this.status,
    required this.title,
    required this.activityId,
    required this.message,
    required this.details,
    required this.percentage,
  });

  final String type;
  final String status;
  final String title;
  final String? activityId;
  final String? message;
  final Map<String, Object?> details;
  final int? percentage;
}

/// Applies the Profile's bounded, declarative activity mappings to sanitized
/// provider events. Unknown provider events are intentionally ignored.
List<ProfileActivityMappingResult> mapProfileActivityEvents(
  Map<String, Object?> profile,
  Iterable<Object?> events,
) {
  final activity = profile['activity'];
  if (activity is! Map || activity['mappings'] is! List) {
    return const [];
  }
  final mappings = (activity['mappings'] as List).whereType<Map>();
  final results = <ProfileActivityMappingResult>[];
  for (final event in events) {
    if (event is! Map) continue;
    for (final mapping in mappings) {
      if (!_matches(event, mapping['when'])) continue;
      final details = <String, Object?>{};
      final selectors = mapping['detailSelectors'];
      if (selectors is Map) {
        for (final entry in selectors.entries) {
          final selector = entry.value;
          if (entry.key is! String || selector is! String) continue;
          if (!_isSafeSelector(selector)) continue;
          final value = selectProfileValue(event, selector);
          if (value == null ||
              value is String ||
              value is bool ||
              value is num) {
            details[entry.key as String] = value;
          }
        }
      }
      final id = mapping['activityIdSelector'];
      final selectedId = id is String ? selectProfileValue(event, id) : null;
      final messageSelector = mapping['messageSelector'];
      final selectedMessage = messageSelector is String
          ? selectProfileValue(event, messageSelector)
          : null;
      results.add(
        ProfileActivityMappingResult(
          type: mapping['type'] as String,
          status: mapping['status'] as String,
          title: mapping['title'] as String,
          activityId: selectedId is String && selectedId.isNotEmpty
              ? selectedId.substring(
                  0,
                  selectedId.length > 128 ? 128 : selectedId.length,
                )
              : null,
          message: selectedMessage is String && selectedMessage.isNotEmpty
              ? selectedMessage.substring(
                  0,
                  selectedMessage.length > 2048 ? 2048 : selectedMessage.length,
                )
              : null,
          details: details,
          percentage: mapping['percentage'] is int
              ? mapping['percentage'] as int
              : null,
        ),
      );
    }
  }
  return results;
}

Object? selectProfileValue(Object? root, String selector) {
  if (!_validSelector(selector)) return null;
  Object? current = root;
  for (final part in selector.substring(2).split('.')) {
    if (current is! Map || !current.containsKey(part)) return null;
    current = current[part];
  }
  return current;
}

bool _matches(Object? event, Object? conditions) {
  if (conditions is! List || conditions.isEmpty) return false;
  for (final raw in conditions) {
    if (raw is! Map) return false;
    final selector = raw['selector'];
    final value =
        selector is String ? selectProfileValue(event, selector) : null;
    switch (raw['kind']) {
      case 'equals':
        if (value != raw['value']) return false;
      case 'not_equals':
        if (value == null || value == raw['value']) return false;
      case 'one_of':
        final values = raw['values'];
        if (values is! List || !values.contains(value)) return false;
      case 'exists':
        if ((value != null) != (raw['exists'] == true)) return false;
      case 'type_is':
        if (_jsonType(value) != raw['value']) return false;
      default:
        return false;
    }
  }
  return true;
}

String _jsonType(Object? value) {
  if (value == null) return 'null';
  if (value is List) return 'array';
  if (value is Map) return 'object';
  if (value is num) return 'number';
  if (value is bool) return 'boolean';
  return 'string';
}

bool _validSelector(String selector) =>
    selector.length <= 256 &&
    RegExp(r'^\$(?:\.[A-Za-z_][A-Za-z0-9_]*)+$').hasMatch(selector) &&
    selector.split('.').length - 1 <= 16 &&
    !selector.split('.').any(
          (part) =>
              const {'__proto__', 'prototype', 'constructor'}.contains(part),
        );

bool _isSafeSelector(String selector) {
  if (!_validSelector(selector)) return false;
  const unsafe = {
    'prompt',
    'content',
    'text',
    'output',
    'stdout',
    'stderr',
    'arguments',
    'command',
    'environment',
    'env',
    'token',
    'secret',
    'password',
    'api_key',
  };
  return !selector
      .substring(2)
      .split('.')
      .any((part) => unsafe.contains(part.toLowerCase()));
}
