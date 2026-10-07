import 'dart:convert';
import 'package:conclave_tool_profile_v1/tool_profile_v1.dart';
import 'package:test/test.dart';
import 'tool_profile_release_test.dart';

void main() {
  Map<String, Object?> profile() {
    final value = validProfileMap();
    final model = value['model'] as Map;
    model['supportedReasoningEfforts'] = ['brief', 'deep'];
    model['defaultReasoningEffort'] = 'brief';
    model['catalog'] = [
      {
        'id': 'a',
        'name': 'A',
        'supportedReasoningEfforts': ['deep'],
        'defaultReasoningEffort': 'deep'
      },
      {'id': 'b', 'name': 'B', 'supportedReasoningEfforts': <String>[]},
    ];
    model['executionOptions'] = {
      'schemaVersion': 1,
      'discovery': 'profile_catalog',
      'modelSwitchSupported': false,
      'effortSupported': true,
      'effortMapping': {'deep': 'provider-native-level'}
    };
    final execution = value['execution'] as Map;
    execution['arguments'] = List<Object?>.from(execution['arguments'] as List);
    (execution['arguments'] as List).add({
      'ifPresent': 'reasoningEffort',
      'values': ['--think', '{{reasoningEffort}}']
    });
    return value;
  }

  test('validates generic options and maps provider-specific effort values',
      () {
    final parsed = EngineProfile.parse(utf8.encode(jsonEncode(profile())));
    final options = ProfileExecutionOptions(parsed.model);
    expect(options.modelSwitchSupported, isFalse);
    expect(options.acceptsEffort('a', 'deep'), isTrue);
    expect(options.acceptsEffort('a', 'brief'), isFalse);
    expect(options.acceptsEffort('b', 'deep'), isFalse);
    expect(options.acceptsEffort('b', null), isTrue);
    expect(options.mapEffort('deep'), 'provider-native-level');
  });
  for (final mutation in [
    'version',
    'discovery',
    'mapping',
    'disabled',
    'duplicate',
    'default',
    'transport'
  ]) {
    test('rejects invalid $mutation execution options', () {
      final value = profile();
      final model = value['model'] as Map;
      final options = model['executionOptions'] as Map;
      if (mutation == 'version') options['schemaVersion'] = 2;
      if (mutation == 'discovery') options['discovery'] = 'dynamic';
      if (mutation == 'mapping')
        (options['effortMapping'] as Map)['unknown'] = 'native';
      if (mutation == 'disabled') options['effortSupported'] = false;
      if (mutation == 'duplicate')
        (model['catalog'] as List).add((model['catalog'] as List).first);
      if (mutation == 'default') options['defaultModelId'] = 'missing';
      if (mutation == 'transport')
        ((value['execution'] as Map)['arguments'] as List).removeLast();
      expect(() => EngineProfile.parse(utf8.encode(jsonEncode(value))),
          throwsFormatException);
    });
  }
}
