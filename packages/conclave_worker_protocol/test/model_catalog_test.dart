import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('probe catalog roundtrips bounded versioned metadata', () {
    final catalog = DiscoveredModelCatalog(
        profileDigest: 'a' * 64,
        providerToolVersion: '1.2.16',
        discoveredAt: '2026-10-11T00:00:00Z',
        models: [
          DiscoveredModel(
            id: 'gemini-new-high',
            name: 'Gemini (High)',
            supportedReasoningEfforts: ['low', 'high'],
            defaultReasoningEffort: 'high',
          )
        ]);
    final probe = ProbeResult(
        requestId: 'probe',
        mode: WorkerProbeMode.passive,
        ready: true,
        checks: [],
        modelCatalog: catalog);
    final restored = decodeWorkerFrame(probe.encode()) as ProbeResult;
    expect(restored.modelCatalog!.toJson(), catalog.toJson());
    expect(() => DiscoveredModel(id: 'bad\n', name: 'Name'),
        throwsFormatException);
    expect(
        () =>
            DiscoveredModel(id: 'safe', name: 'Name', status: 'authenticated'),
        throwsFormatException);
    expect(
        () => DiscoveredModelCatalog(
            profileDigest: 'a' * 64,
            providerToolVersion: '1.2.16',
            discoveredAt: '2026-10-11T00:00:00Z',
            models: [...catalog.models, ...catalog.models]),
        throwsFormatException);
    expect(
        () => DiscoveredModel(
            id: 'safe',
            name: 'Name',
            supportedReasoningEfforts: ['low'],
            defaultReasoningEffort: 'high'),
        throwsFormatException);
  });
  test('v2 local mapping roundtrips while inventory strips native IDs', () {
    DiscoveredModelCatalog catalog(
            {String version = '1.3.3',
            String time = '2026-10-11T00:00:00Z',
            String status = 'listed'}) =>
        DiscoveredModelCatalog(
            schemaVersion: 2,
            profileDigest: 'a' * 64,
            providerToolVersion: version,
            discoveredAt: time,
            models: [
              DiscoveredModel(
                  id: 'logical',
                  nativeId: 'native-high',
                  name: 'Logical',
                  selectionMode: 'combined',
                  status: status,
                  supportedReasoningEfforts: ['high'],
                  defaultReasoningEffort: 'high')
            ]);
    final local = catalog();
    expect(
        DiscoveredModelCatalog.fromJson(local.toJson()).models.single.nativeId,
        'native-high');
    expect(local.toJson(includeNativeIds: false).toString(),
        isNot(contains('native-high')));
    expect(local.catalogRevision,
        catalog(time: '2026-10-11T01:00:00Z').catalogRevision);
    expect(local.catalogRevision,
        isNot(catalog(version: '1.3.4').catalogRevision));
    expect(local.catalogRevision,
        isNot(catalog(status: 'verified').catalogRevision));
    expect(
        () => DiscoveredModelCatalog.fromJson(
            {...local.toJson(), 'catalogRevision': 'b' * 64}),
        throwsFormatException);
    expect(
        () => DiscoveredModel(
            id: 'a', name: 'A', supportedReasoningEfforts: ['high', 'high']),
        throwsFormatException);
    final missing = {
      ...local.toJson(),
      'models': [
        {
          'id': 'a',
          'name': 'A',
          'selectionMode': 'separate',
          'status': 'listed'
        }
      ]
    };
    expect(
        DiscoveredModelCatalog.fromJson(missing)
            .models
            .single
            .supportedReasoningEfforts,
        isEmpty);
  });
  test('stale state survives round trips without changing capability revision',
      () {
    final fresh = DiscoveredModelCatalog(
        schemaVersion: 2,
        profileDigest: 'a' * 64,
        providerToolVersion: '1.3.3',
        discoveredAt: '2026-10-11T00:00:00Z',
        models: [DiscoveredModel(id: 'one', name: 'One')]);
    final stale = fresh.withStale(true);
    expect(stale.catalogRevision, fresh.catalogRevision);
    expect(DiscoveredModelCatalog.fromJson(stale.toJson()).stale, isTrue);
    expect(stale.withStale(false).catalogRevision, fresh.catalogRevision);
    expect(
        () => DiscoveredModelCatalog.fromJson(
            {...stale.toJson(), 'stale': 'true'}),
        throwsFormatException);
  });
}
