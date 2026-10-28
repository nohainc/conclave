import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:syntila_workspace/cloud_connection.dart';
import 'package:syntila_workspace/input_delivery.dart';
import 'package:syntila_workspace/thread_directory.dart';
import 'package:syntila_workspace/thread_path.dart';
import 'package:syntila_workspace/work_request_input_staging.dart';
import 'package:syntila_workspace/worker_executor.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import 'support/assignment_worker_fixture.dart';

const _fileA = 'wrf-11111111-2222-3333-4444-555555555555';
const _fileB = 'wrf-11111111-2222-3333-4444-666666666666';
const _requestId = 'work-request-11111111-2222-3333-4444-555555555555';

String _digest(List<int> bytes) => 'sha256:${sha256.convert(bytes)}';

Stream<List<int>> _chunks(List<int> bytes) => Stream.fromIterable(
    [bytes.sublist(0, bytes.length ~/ 2), bytes.sublist(bytes.length ~/ 2)]);

class FakeDeliveryCloud implements InputDeliveryCloud {
  FakeDeliveryCloud(this.files);

  final Map<String, List<int>> files;
  final pending = <PendingWorkRequestInput>[];
  final delivered = <String>[];
  final attempts = <(String, bool, String)>[];
  final downloads = <String>[];
  int failuresBeforeSuccess = 0;
  Completer<void>? holdDownloads;
  int activeDownloads = 0, maxActiveDownloads = 0;

  PendingWorkRequestInput input(String fileId, {String? digest}) =>
      PendingWorkRequestInput(
        fileId: fileId,
        workRequestId: _requestId,
        name: '$fileId.txt',
        sizeBytes: files[fileId]!.length,
        contentDigest: digest ?? _digest(files[fileId]!),
      );

  @override
  Future<List<PendingWorkRequestInput>> listPending() async => [
        for (final item in pending)
          if (!delivered.contains(item.fileId)) item
      ];

  @override
  Future<Stream<List<int>>> download(String fileId) async {
    downloads.add(fileId);
    activeDownloads++;
    if (activeDownloads > maxActiveDownloads) {
      maxActiveDownloads = activeDownloads;
    }
    try {
      await holdDownloads?.future;
      if (failuresBeforeSuccess > 0) {
        failuresBeforeSuccess--;
        // Truncated transfer: the store must reject and discard it.
        return Stream.value(files[fileId]!.sublist(1));
      }
      return _chunks(files[fileId]!);
    } finally {
      activeDownloads--;
    }
  }

  @override
  Future<void> confirmDelivered(String fileId, String contentDigest) async =>
      delivered.add(fileId);

  @override
  Future<void> reportAttempt(String fileId,
          {required bool finalAttempt, required String message}) async =>
      attempts.add((fileId, finalAttempt, message));
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue);
}

void main() {
  late Directory root;
  late WorkRequestInputStaging staging;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('input-delivery-');
    staging = WorkRequestInputStaging(Directory('${root.path}/staged'));
  });
  tearDown(() => root.delete(recursive: true));

  group('store', () {
    test('streams verified content and reads it back', () async {
      final bytes = utf8.encode('hello world');
      await staging.stageStream(
          fileId: _fileA,
          sizeBytes: bytes.length,
          contentDigest: _digest(bytes),
          content: _chunks(bytes));
      expect(await staging.contains(_fileA), isTrue);
      expect(
          await staging.read(
              fileId: _fileA,
              sizeBytes: bytes.length,
              contentDigest: _digest(bytes)),
          bytes);
      expect(File('${root.path}/staged/$_fileA.partial').existsSync(), isFalse);
    });

    test('discards content that does not match its digest or size', () async {
      final bytes = utf8.encode('hello');
      await expectLater(
          staging.stageStream(
              fileId: _fileA,
              sizeBytes: 5,
              contentDigest: _digest(utf8.encode('other')),
              content: _chunks(bytes)),
          throwsA(isA<WorkRequestInputStagingException>()
              .having((e) => e.code, 'code', 'digest_mismatch')));
      await expectLater(
          staging.stageStream(
              fileId: _fileA,
              sizeBytes: 4,
              contentDigest: _digest(bytes),
              content: _chunks(bytes)),
          throwsA(isA<WorkRequestInputStagingException>()
              .having((e) => e.code, 'code', 'size_mismatch')));
      expect(await staging.contains(_fileA), isFalse);
      expect(Directory('${root.path}/staged').listSync(), isEmpty);
    });

    test('rejects unsafe file identities', () async {
      await expectLater(
          staging.stageStream(
              fileId: '../escape',
              sizeBytes: 1,
              contentDigest: _digest([1]),
              content: Stream.value([1])),
          throwsA(isA<WorkRequestInputStagingException>()));
      expect(Directory('${root.path}/staged').existsSync(), isFalse);
    });

    test('reports changed content on read', () async {
      final bytes = utf8.encode('hello');
      await staging.stageStream(
          fileId: _fileA,
          sizeBytes: 5,
          contentDigest: _digest(bytes),
          content: _chunks(bytes));
      await File('${root.path}/staged/$_fileA').writeAsString('HELLO');
      await expectLater(
          staging.read(
              fileId: _fileA, sizeBytes: 5, contentDigest: _digest(bytes)),
          throwsA(isA<WorkRequestInputStagingException>()
              .having((e) => e.code, 'code', 'staged_input_changed')));
    });

    test('prunes files past retention', () async {
      final old =
          File('${root.path}/staged/wrf-00000000-0000-0000-0000-000000000000');
      await old.create(recursive: true);
      await old
          .setLastModified(DateTime.now().subtract(const Duration(days: 8)));
      final bytes = utf8.encode('hello');
      await staging.stageStream(
          fileId: _fileA,
          sizeBytes: 5,
          contentDigest: _digest(bytes),
          content: _chunks(bytes));
      expect(old.existsSync(), isFalse);
    });
  });

  group('agent', () {
    InputDeliveryAgent agent(FakeDeliveryCloud cloud) {
      final value = InputDeliveryAgent(
        cloud: cloud,
        staging: staging,
        maxConcurrent: 2,
        activePollInterval: const Duration(milliseconds: 10),
        idlePollInterval: const Duration(milliseconds: 20),
        retryDelay: Duration.zero,
      );
      addTearDown(value.stop);
      return value;
    }

    test('downloads files in parallel as they become available', () async {
      final cloud = FakeDeliveryCloud({
        _fileA: utf8.encode('first file'),
        _fileB: utf8.encode('second file'),
      });
      cloud.holdDownloads = Completer<void>();
      final delivery = agent(cloud)..start();
      cloud.pending.add(cloud.input(_fileA));
      delivery.wake();
      // The second file is uploaded while the first is downloading.
      await _until(() => cloud.downloads.contains(_fileA));
      cloud.pending.add(cloud.input(_fileB));
      delivery.wake();
      await _until(() => cloud.downloads.contains(_fileB));
      expect(cloud.maxActiveDownloads, 2);
      cloud.holdDownloads!.complete();
      await _until(() => cloud.delivered.length == 2);
      expect(cloud.delivered.toSet(), {_fileA, _fileB});
      expect(cloud.downloads.where((id) => id == _fileA), hasLength(1));
    });

    test('restarts a failed file from scratch and reports the attempt',
        () async {
      final cloud = FakeDeliveryCloud({_fileA: utf8.encode('content')})
        ..failuresBeforeSuccess = 1;
      cloud.pending.add(cloud.input(_fileA));
      agent(cloud).start();
      await _until(() => cloud.delivered.contains(_fileA));
      expect(cloud.downloads, [_fileA, _fileA]);
      expect(cloud.attempts.single.$2, isFalse);
      expect(await staging.contains(_fileA), isTrue);
    });

    test('reports a final failure after its attempts', () async {
      final cloud = FakeDeliveryCloud({_fileA: utf8.encode('content')})
        ..failuresBeforeSuccess = 99;
      cloud.pending.add(cloud.input(_fileA));
      agent(cloud).start();
      await _until(() => cloud.attempts.any((attempt) => attempt.$2));
      expect(cloud.attempts, hasLength(3));
      expect(cloud.delivered, isEmpty);
      expect(await staging.contains(_fileA), isFalse);
    });
  });

  group('assignment materialization', () {
    WorkspaceAssignmentContext context(Map<String, Object?> attachment) =>
        WorkspaceAssignmentContext(
          workspaceId: 'workspace-1',
          workspaceRuntimeId: 'runtime-1',
          workerId: 'worker',
          runId: 'run',
          taskId: 'task',
          attemptId: 'attempt',
          assignmentId: 'assignment',
          idempotencyKey: 'key',
          payload: {
            'workerId': 'worker',
            'workerTypeId': 'test-worker',
            'spaceId': 'space',
            'threadId': 'thread',
            'executionClass': 'stateless_read',
            'workRequestId': _requestId,
            'input': {
              'attachments': [attachment]
            },
          },
        );

    WorkerAssignmentHandler handler({WorkRequestInputFetcher? fetch}) {
      Directory('${root.path}/work').createSync();
      return WorkerAssignmentHandler(
        threadDirectoryLifecycle: ThreadDirectoryLifecycle(
          pathResolver: ThreadPathResolver(Directory('${root.path}/work')),
        ),
        inputStaging: staging,
        fetchInput: fetch,
        resolveLogicalWorker: (id) => assignmentWorker(id),
      );
    }

    Map<String, Object?> attachment(List<int> bytes) => {
          'kind': 'file',
          'fileId': _fileA,
          'sizeBytes': bytes.length,
          'contentDigest': _digest(bytes),
        };

    test('copies a delivered file into the execution directory', () async {
      final bytes = utf8.encode('delivered content');
      await staging.stageStream(
          fileId: _fileA,
          sizeBytes: bytes.length,
          contentDigest: _digest(bytes),
          content: _chunks(bytes));
      final scope =
          await handler().prepareAssignmentScope(context(attachment(bytes)));
      final file = File('${scope.workingDirectory.path}/.conclave/inputs/'
          '$_requestId/file-001');
      expect(await file.readAsBytes(), bytes);
    });

    test('re-downloads a file the store no longer has', () async {
      final bytes = utf8.encode('delivered content');
      final fetched = <String>[];
      final scope = await handler(fetch: (
          {required fileId, required sizeBytes, required contentDigest}) async {
        fetched.add(fileId);
        await staging.stageStream(
            fileId: fileId,
            sizeBytes: sizeBytes,
            contentDigest: contentDigest,
            content: _chunks(bytes));
      }).prepareAssignmentScope(context(attachment(bytes)));
      expect(fetched, [_fileA]);
      expect(
          await File('${scope.workingDirectory.path}/.conclave/inputs/'
                  '$_requestId/file-001')
              .readAsBytes(),
          bytes);
    });

    test('fails before launch when the file is unavailable', () async {
      await expectLater(
          handler().prepareAssignmentScope(
              context(attachment(utf8.encode('missing')))),
          throwsA(isA<AssignmentExecutionFailure>()));
    });

    test('rejects inline content and unsafe identities', () async {
      await expectLater(
          handler().prepareAssignmentScope(context({
            'kind': 'file',
            'sizeBytes': 5,
            'contentBase64': base64Encode(utf8.encode('hello')),
          })),
          throwsStateError);
    });
  });
}
