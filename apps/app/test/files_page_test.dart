import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/ax/ax_data.dart';
import 'package:conclave_app/src/features/files/files_page.dart';
import 'package:conclave_app/src/navigation/ax_navigation.dart';

class _FakeFiles implements AxUserFilesDataSource {
  _FakeFiles(this.files);

  final List<AxUserFile> files;
  final deleted = <String>[];
  bool failSync = false;
  int syncCount = 0;

  @override
  Future<void> syncUserFiles() async {
    syncCount++;
    if (failSync) throw Exception('offline');
    files.clear();
  }

  static const quota = 1024 * 1024 * 1024;

  AxStorageUsage get _usage => AxStorageUsage(
        usedBytes: files.fold(0, (sum, file) => sum + file.sizeBytes),
        fileCount: files.length,
        quotaBytes: quota,
      );

  @override
  Future<AxUserFilesPage> loadUserFiles({String? before}) async =>
      AxUserFilesPage(files: [...files], usage: _usage);

  @override
  Future<AxStorageUsage> deleteUserFile(String fileId) async {
    deleted.add(fileId);
    files.removeWhere((file) => file.fileId == fileId);
    return _usage;
  }
}

void main() {
  test('My Files has its own route', () {
    final route = AxNavigation.fromUri(Uri(path: '/files'));
    expect(route.kind, AxRouteKind.files);
    expect(route.toUri().path, '/files');
  });

  test('formats sizes', () {
    expect(formatFileSize(512), '512 B');
    expect(formatFileSize(1536), '1.5 KB');
    expect(formatFileSize(10 * 1024 * 1024), '10 MB');
  });

  testWidgets(
      'synchronizes storage, reloads usage and allows retry after failure',
      (tester) async {
    final source = _FakeFiles([])..failSync = true;
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: FilesPage(source: source))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Synchronize storage'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Synchronization could not finish'),
        findsOneWidget);
    source.failSync = false;
    await tester.tap(find.text('Synchronize storage'));
    await tester.pumpAndSettle();
    expect(source.syncCount, 2);
    expect(find.text('Files synchronized with storage.'), findsOneWidget);
    expect(
        find.textContaining('Synchronization could not finish'), findsNothing);
    expect(find.textContaining('0 files'), findsOneWidget);
  });

  testWidgets('lists uploads with usage and deletes a file', (tester) async {
    final source = _FakeFiles([
      const AxUserFile(
        fileId: 'wrf-a',
        name: 'plan.pdf',
        mediaType: 'application/pdf',
        sizeBytes: 2 * 1024 * 1024,
        createdAt: '2026-10-01T10:00:00.000Z',
        threadId: 'thread',
        spaceId: 'space',
        threadName: 'Plan',
        spaceName: 'Team',
        inUse: true,
      ),
      const AxUserFile(
        fileId: 'wrf-b',
        name: 'notes.txt',
        mediaType: 'text/plain',
        sizeBytes: 1024,
        createdAt: '2026-10-02T10:00:00.000Z',
      ),
    ]);
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: FilesPage(source: source))));
    await tester.pumpAndSettle();

    expect(find.text('plan.pdf'), findsOneWidget);
    expect(find.textContaining('Team > Plan'), findsOneWidget);
    expect(find.textContaining('In use'), findsOneWidget);
    expect(find.textContaining('Thread no longer available'), findsOneWidget);
    expect(find.textContaining('of 1 GB used · 2 files'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('delete-file-wrf-a')));
    await tester.pumpAndSettle();
    expect(find.textContaining('can no longer be downloaded'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('confirm-delete-file')));
    await tester.pumpAndSettle();

    expect(source.deleted, ['wrf-a']);
    expect(find.text('plan.pdf'), findsNothing);
    expect(find.textContaining('1 file'), findsOneWidget);
  });
}
