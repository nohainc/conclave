import 'package:conclave_app/src/ax/sync/persistence/ax_read_cache_codec.dart';
import 'package:conclave_app/src/ax/ax_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
      'catalog refresh preserves saved selections until deliberate replacement',
      () {
    const refreshed = AxWorkerExecutionOptions(
      modelSelectionSupported: true,
      modelDiscovery: 'profile_catalog',
      allowsCustomModel: true,
      allowedModelIds: ['new'],
      models: [],
      modelSwitchSupported: true,
      effort: AxWorkerEffortOptions(supported: true, values: ['brief']),
    );
    expect(refreshed.reconcileSelection(model: 'removed', effort: 'deep'),
        (model: 'removed', effort: 'deep'));
    expect(refreshed.reconcileSelection(model: 'new', effort: 'brief'),
        (model: 'new', effort: 'brief'));
    // Default does not become an explicit catalog model or effort.
    expect(refreshed.reconcileSelection(), (model: null, effort: null));
  });

  test('reads versioned generic capabilities and model-specific effort', () {
    final worker = AxWorker.fromJson({
      'id': 'worker',
      'executionOptions': {
        'schemaVersion': 1,
        'models': {
          'supported': true,
          'discovery': 'profile_catalog',
          'allowsCustomModel': false,
          'allowedModelIds': ['a', 'b'],
          'defaultModelId': 'b',
          'options': [
            {
              'id': 'a',
              'name': 'A',
              'effort': {
                'supported': true,
                'values': ['brief', 'deep'],
                'defaultValue': 'brief'
              }
            },
            {
              'id': 'b',
              'name': 'B',
              'effort': {
                'supported': false,
                'values': <String>[],
                'defaultValue': null
              }
            },
          ]
        },
        'modelSwitch': {'supported': false},
        'effort': {
          'supported': true,
          'values': ['normal'],
          'defaultValue': 'normal'
        },
      }
    });
    final options = worker.executionOptions!;
    expect(AxWorkerExecutionOptions.fromJson(options.toJson()).models.length,
        options.models.length);
    expect(options.reconcileSelection(model: 'foreign', effort: 'deep'),
        (model: 'foreign', effort: 'deep'));
    expect(options.reconcileSelection(model: 'a', effort: 'deep'),
        (model: 'a', effort: 'deep'));
    expect(options.reconcileSelection(model: 'a', effort: 'obsolete'),
        (model: 'a', effort: 'obsolete'));
    expect(options.reconcileSelection(model: 'b', effort: 'deep'),
        (model: 'b', effort: 'deep'));
    expect(options.reconcileSelection(), (model: null, effort: null));
    expect(options.modelSwitchSupported, isFalse);
    expect(options.effortsForModel('a').values, ['brief', 'deep']);
    expect(options.effortsForModel(null).supported, isFalse);
    expect(() => options.allowedModelIds.add('other'), throwsUnsupportedError);
    expect(AxWorker.fromJson({'id': 'older'}).executionOptions, isNull);
  });
  test('v2 reads unified options and rejects unsupported metadata', () {
    final json = <String, dynamic>{
      'schemaVersion': 2,
      'catalogRevision': 'a' * 64,
      'models': {
        'supported': true,
        'discovery': 'provider_catalog',
        'allowsCustomModel': false,
        'allowedModelIds': ['model'],
        'defaultModelId': null,
        'options': [
          {
            'id': 'model',
            'name': 'Model',
            'selectionMode': 'combined',
            'status': 'listed',
            'efforts': ['low', 'medium', 'high', 'xhigh', 'max', 'ultra'],
            'defaultEffort': 'low'
          },
          {
            'id': 'retired',
            'name': 'Retired',
            'selectionMode': 'separate',
            'status': 'unavailable'
          }
        ]
      },
      'modelSwitch': {'supported': true},
      'effort': {'supported': false, 'values': [], 'defaultValue': null}
    };
    json['catalogStale'] = true;
    final options = AxWorkerExecutionOptions.fromJson(json);
    expect(options.catalogStale, isTrue);
    expect(options.catalogRevision, 'a' * 64);
    final cached =
        AxWorker.fromJson(AxReadCacheCodec().worker(AxWorker.fromJson({
      'id': 'worker',
      'executionOptions': {...json, 'catalogStale': true}
    })));
    expect(cached.executionOptions!.catalogRevision, options.catalogRevision);
    expect(cached.executionOptions!.catalogStale, isTrue);
    expect(cached.executionOptions!.toJson()['models'],
        options.toJson()['models']);
    expect(options.models.first.selectionMode, 'combined');
    expect(options.effortsForModel('model').values, hasLength(6));
    expect(options.reconcileSelection(model: 'model', effort: 'ultra'),
        (model: 'model', effort: 'ultra'));
    expect(options.reconcileSelection(model: 'retired'),
        (model: 'retired', effort: null));
    expect(options.reconcileSelection(), (model: null, effort: null));
    final models = json['models'] as Map;
    final entries = models['options'] as List;
    for (final invalid in [
      {
        ...entries.first as Map,
        'efforts': ['high', 'high']
      },
      {...entries.first as Map, 'defaultEffort': 'unknown'},
      {...entries.first as Map, 'selectionMode': 'guessed'},
    ]) {
      models['options'] = [invalid];
      expect(
          () => AxWorkerExecutionOptions.fromJson(json), throwsFormatException);
    }
    models['options'] = [entries.first, entries.first];
    expect(
        () => AxWorkerExecutionOptions.fromJson(json), throwsFormatException);
  });
}
