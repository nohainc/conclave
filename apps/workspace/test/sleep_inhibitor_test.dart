import 'dart:io';

import 'package:conclave_workspace/sleep_inhibitor.dart';
import 'package:conclave_workspace/workspace_lifecycle_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('preventSleep defaults on and toggles the inhibitor', () async {
    final dir = Directory.systemTemp.createTempSync('sleep');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = WorkspaceLifecyclePreferencesStore(dir);
    expect(store.readSync().preventSleep, isTrue);

    final inhibitor = SleepInhibitor(
      store,
      platformIsMacOS: true,
      pollInterval: const Duration(milliseconds: 50),
      start: (_) => Process.start('/bin/sleep', ['30']),
    );
    await inhibitor.begin();
    expect(inhibitor.isHeld, isTrue);

    await store.write(store.readSync().copyWith(preventSleep: false));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(inhibitor.isHeld, isFalse);
    expect(store.readSync().preventSleep, isFalse);
    await inhibitor.close();
  });
}
