import 'dart:convert';
import 'dart:io';

import 'package:conclave_fixture_cli_worker/fixture_cli_worker.dart';
import 'package:test/test.dart';

void main() {
  test('development catalog registers a non-product third Worker', () async {
    final root = Directory.current.parent.parent;
    final catalog =
        jsonDecode(
              await File(
                '${root.path}/workers/development_catalog.json',
              ).readAsString(),
            )
            as Map<String, Object?>;
    final entries = catalog['entries']! as List;
    final fixture = entries.cast<Map>().singleWhere(
      (entry) => entry['workerTypeId'] == FixtureCliWorker.workerTypeId,
    );
    expect(fixture['packagePath'], 'workers/fixture_cli');
    expect(fixture['releaseChannel'], 'development');
    expect(fixture['developmentOnly'], isTrue);
    expect(fixture['productCatalog'], isFalse);
  });

  test('fixture Worker uses the shared Worker Protocol runtime', () {
    final identity = FixtureCliWorker().createRuntime().identity;
    expect(identity.workerTypeId, 'fixture_cli');
    expect(identity.workerVersion, '0.1.0');
    expect(
      identity.capabilities,
      containsAll(['initialize', 'probe', 'execute']),
    );
  });
}
