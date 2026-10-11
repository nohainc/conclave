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
}
