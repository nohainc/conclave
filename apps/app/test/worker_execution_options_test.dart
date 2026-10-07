import 'package:conclave_app/src/ax/ax_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('catalog refresh drops removed options and respects custom allowlists',
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
        (model: null, effort: null));
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
    expect(options.reconcileSelection(model: 'foreign', effort: 'deep'),
        (model: null, effort: null));
    expect(options.reconcileSelection(model: 'a', effort: 'deep'),
        (model: 'a', effort: 'deep'));
    expect(options.reconcileSelection(model: 'a', effort: 'obsolete'),
        (model: 'a', effort: null));
    expect(options.reconcileSelection(model: 'b', effort: 'deep'),
        (model: 'b', effort: null));
    expect(options.reconcileSelection(), (model: null, effort: null));
    expect(options.modelSwitchSupported, isFalse);
    expect(options.effortsForModel('a').values, ['brief', 'deep']);
    expect(options.effortsForModel(null).supported, isFalse);
    expect(() => options.allowedModelIds.add('other'), throwsUnsupportedError);
    expect(AxWorker.fromJson({'id': 'older'}).executionOptions, isNull);
  });
}
