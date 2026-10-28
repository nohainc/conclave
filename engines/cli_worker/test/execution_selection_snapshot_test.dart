import 'dart:io';
import 'package:test/test.dart';
import 'package:syntila_cli_worker_engine/src/execution_selection_snapshot.dart';

void main() {
  test(
    'local selection evidence survives restart and cannot be rewritten',
    () async {
      final root = await Directory.systemTemp.createTemp('selection-snapshot-');
      addTearDown(() => root.delete(recursive: true));
      final snapshot = <String, Object?>{
        'schemaVersion': 1,
        'modelId': 'family',
        'effort': 'high',
        'resolvedNativeModelId': 'family-high',
      };
      await ExecutionSelectionSnapshotStore(
        root.path,
      ).write('invocation', snapshot);
      await ExecutionSelectionSnapshotStore(
        root.path,
      ).write('invocation', snapshot);
      await expectLater(
        ExecutionSelectionSnapshotStore(
          root.path,
        ).write('invocation', {...snapshot, 'effort': 'low'}),
        throwsFormatException,
      );
      await ExecutionSelectionSnapshotStore(root.path).write('invocation', {
        'status': 'completed',
        'selectionObservation': 'unavailable',
      }, completion: true);
      expect(
        Directory('${root.path}/execution-selections')
            .listSync()
            .whereType<File>()
            .where((file) => file.path.endsWith('.json')),
        hasLength(2),
      );
    },
  );
  test('local audit rejects symbolic link directories', () async {
    final root = await Directory.systemTemp.createTemp('selection-snapshot-');
    final other = await Directory.systemTemp.createTemp('selection-outside-');
    addTearDown(() async {
      await root.delete(recursive: true);
      await other.delete(recursive: true);
    });
    await Link('${root.path}/execution-selections').create(other.path);
    await expectLater(
      ExecutionSelectionSnapshotStore(root.path).write('invocation', {}),
      throwsFormatException,
    );
    expect(other.listSync(), isEmpty);
  });
}
