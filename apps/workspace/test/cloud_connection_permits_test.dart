import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:syntila_protocol/workspace_runtime_protocol.dart'
    show workspaceRuntimeProtocolVersion;
import 'package:syntila_workspace/assignment_journal.dart';
import 'package:syntila_workspace/assignment_trace.dart';
import 'package:syntila_workspace/cloud_connection.dart';
import 'package:test/test.dart';

import 'support/cloud_connection_test_support.dart';

void main() {
  group('start permit and durable cancellation', () {
    Map<String, Object?> envelope(
            String type, String assignmentId, Map<String, Object?> payload,
            {String attemptId = 'attempt-1'}) =>
        {
          'protocol': 'syntila.workspace-runtime-protocol',
          'protocolVersion': workspaceRuntimeProtocolVersion,
          'messageId': 'm-$type-$assignmentId',
          'timestamp': DateTime.now().toUtc().toIso8601String(),
          'type': type,
          'executionWorkspaceId': 'workspace-1',
          'workspaceRuntimeId': 'runtime-1',
          'workerId': 'worker-1',
          'runId': 'run-1',
          'taskId': 'task-1',
          'attemptId': attemptId,
          'assignmentId': assignmentId,
          'idempotencyKey': 'idem-$assignmentId',
          'payload': payload,
        };

    WorkspaceAssignmentContext contextFor(String assignmentId,
            {bool required = true, String attemptId = 'attempt-1'}) =>
        WorkspaceAssignmentContext(
          workspaceId: 'workspace-1',
          workspaceRuntimeId: 'runtime-1',
          workerId: 'worker-1',
          runId: 'run-1',
          taskId: 'task-1',
          attemptId: attemptId,
          assignmentId: assignmentId,
          idempotencyKey: 'idem-$assignmentId',
          payload: {
            if (required) 'startPermit': {'required': true},
          },
        );

    Future<(WorkspaceCloudConnection, FakeSocket)> connected(
        {AssignmentJournal? journal,
        WorkspaceAssignmentHandler? handler,
        bool withClockSample = true,
        MonotonicCloudClock? startPermitClock}) async {
      final socket = FakeSocket();
      final connection = WorkspaceCloudConnection(
        uri: Uri.parse(
            'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-1'),
        workspaceRuntimeId: 'runtime-1',
        workspaceId: 'workspace-1',
        factory: (_) async => socket,
        assignmentJournal: journal,
        assignmentHandler: handler,
        startPermitClock: startPermitClock,
      );
      await connection.connect();
      await completeHandshake(connection, socket,
          serverTime: withClockSample ? DateTime.now().toUtc() : null);
      return (connection, socket);
    }

    List<Map<String, dynamic>> sentOfType(FakeSocket socket, String type) =>
        socket.sent
            .map((m) => jsonDecode(m as String) as Map<String, dynamic>)
            .where((m) => m['type'] == type)
            .toList();

    test('advertises the start permit capability', () async {
      final (connection, socket) = await connected();
      final hello = sentOfType(socket, 'workspace.hello').first;
      final capabilities =
          (hello['payload'] as Map)['capabilities'] as Map<String, dynamic>;
      expect(capabilities['customCapabilities'],
          contains(WorkspaceCloudConnection.startPermitCapability));
      await connection.close();
    });

    test('does not request a permit when Cloud does not require one', () async {
      final (connection, socket) = await connected();
      expect(
          await connection
              .requestStartPermit(contextFor('legacy', required: false)),
          isTrue);
      expect(sentOfType(socket, 'assignment.start.permit.request'), isEmpty);
      await connection.close();
    });

    test('grants launch only after Cloud returns a matching grant', () async {
      final (connection, socket) = await connected();
      final context = contextFor('assignment-permit');
      final result = connection.requestStartPermit(context);
      await waitFor(() =>
          sentOfType(socket, 'assignment.start.permit.request').isNotEmpty);
      socket.controller.add(jsonEncode(envelope(
        'assignment.start.permit.grant',
        'assignment-permit',
        {
          'granted': true,
          'permitId': 'permit-1',
          'expiresAt': DateTime.now()
              .toUtc()
              .add(const Duration(seconds: 30))
              .toIso8601String(),
        },
      )));
      expect(await result, isTrue);
      await connection.close();
    });

    test(
        'a permit prefetched at admission authorizes launch without a '
        'second request', () async {
      final (connection, socket) = await connected();
      final context = contextFor('assignment-prefetch');
      connection.prefetchStartPermit(context);
      await waitFor(() =>
          sentOfType(socket, 'assignment.start.permit.request').isNotEmpty);
      socket.controller.add(jsonEncode(envelope(
        'assignment.start.permit.grant',
        'assignment-prefetch',
        {
          'granted': true,
          'permitId': 'permit-1',
          'expiresAt': DateTime.now()
              .toUtc()
              .add(const Duration(seconds: 30))
              .toIso8601String(),
        },
      )));
      expect(await connection.requestStartPermit(context), isTrue);
      expect(
          sentOfType(socket, 'assignment.start.permit.request'), hasLength(1));
      await connection.close();
    });

    test('a denied prefetched permit asks Cloud again at launch', () async {
      final (connection, socket) = await connected();
      final context = contextFor('assignment-prefetch-denied');
      connection.prefetchStartPermit(context);
      await waitFor(() =>
          sentOfType(socket, 'assignment.start.permit.request').isNotEmpty);
      socket.controller.add(jsonEncode(envelope(
        'assignment.start.permit.grant',
        'assignment-prefetch-denied',
        {'granted': false, 'reason': 'revoked'},
      )));
      final result = connection.requestStartPermit(context);
      await waitFor(() =>
          sentOfType(socket, 'assignment.start.permit.request').length == 2);
      socket.controller.add(jsonEncode(envelope(
        'assignment.start.permit.grant',
        'assignment-prefetch-denied',
        {'granted': false, 'reason': 'revoked'},
      )));
      expect(await result, isFalse);
      await connection.close();
    });

    test('a denied permit blocks launch', () async {
      final (connection, socket) = await connected();
      final result = connection.requestStartPermit(contextFor('revoked-one'));
      await waitFor(() =>
          sentOfType(socket, 'assignment.start.permit.request').isNotEmpty);
      socket.controller.add(jsonEncode(envelope(
        'assignment.start.permit.grant',
        'revoked-one',
        {'granted': false, 'reason': 'revoked'},
      )));
      expect(await result, isFalse);
      await connection.close();
    });

    test('repeated stale runtime grants cannot authorize a replacement runtime',
        () async {
      final (connection, socket) = await connected();
      addTearDown(connection.close);
      for (var iteration = 0; iteration < 20; iteration++) {
        final id = 'replacement-$iteration';
        final result = connection.requestStartPermit(contextFor(id));
        await waitFor(() =>
            sentOfType(socket, 'assignment.start.permit.request')
                .any((message) => message['assignmentId'] == id));
        socket.controller.add(jsonEncode(envelope(
          'assignment.start.permit.grant',
          id,
          {
            'granted': true,
            'permitId': 'stale-$iteration',
            'expiresAt': DateTime.now()
                .toUtc()
                .add(const Duration(seconds: 30))
                .toIso8601String(),
          },
        )..['workspaceRuntimeId'] = 'replaced-runtime'));
        socket.controller.add(jsonEncode(envelope(
          'assignment.start.permit.grant',
          id,
          {'granted': false, 'reason': 'revoked'},
        )));
        expect(await result, isFalse, reason: 'iteration $iteration');
      }
    });

    test('expired and malformed grants fail closed', () async {
      final (connection, socket) = await connected();
      addTearDown(connection.close);
      for (final expiry in [
        DateTime.utc(2000).toIso8601String(),
        'invalid',
        null,
      ]) {
        final id = 'expiry-$expiry';
        final result = connection.requestStartPermit(contextFor(id));
        await waitFor(() =>
            sentOfType(socket, 'assignment.start.permit.request')
                .any((message) => message['assignmentId'] == id));
        socket.controller.add(jsonEncode(envelope(
          'assignment.start.permit.grant',
          id,
          {'granted': true, 'permitId': 'expired', 'expiresAt': expiry},
        )));
        expect(await result, isFalse);
      }
    });

    test('permit expiry uses conservative Cloud time for either clock skew',
        () async {
      for (final skewSeconds in [-120, 120]) {
        for (final remainingSeconds in [-1, 30]) {
          final (connection, socket) = await connected(withClockSample: false);
          try {
            final now = DateTime.now().toUtc();
            connection.clockOffset.addSample(
              sentAtUtc: now,
              roundTrip: const Duration(milliseconds: 100),
              serverTimeUtc:
                  now.add(Duration(seconds: skewSeconds, milliseconds: 50)),
            );
            connection.startPermitClock.addSample(
              serverTimeUtc:
                  now.add(Duration(seconds: skewSeconds, milliseconds: 50)),
              roundTrip: const Duration(milliseconds: 100),
            );
            final id = 'skew-$skewSeconds-$remainingSeconds';
            final result = connection.requestStartPermit(contextFor(id));
            await waitFor(() =>
                sentOfType(socket, 'assignment.start.permit.request')
                    .isNotEmpty);
            socket.controller.add(jsonEncode(envelope(
              'assignment.start.permit.grant',
              id,
              {
                'granted': true,
                'permitId': 'skew-permit',
                'expiresAt': now
                    .add(Duration(seconds: skewSeconds + remainingSeconds))
                    .toIso8601String(),
              },
            )));
            expect(await result, remainingSeconds > 0,
                reason: 'Cloud offset $skewSeconds, TTL $remainingSeconds');
          } finally {
            await connection.close();
          }
        }
      }
    });

    test('missing clock sample or expiry within RTT uncertainty denies launch',
        () async {
      for (final sampled in [false, true]) {
        final (connection, socket) = await connected(withClockSample: false);
        try {
          final now = DateTime.now().toUtc();
          if (sampled) {
            connection.clockOffset.addSample(
              sentAtUtc: now,
              roundTrip: const Duration(seconds: 10),
              serverTimeUtc: now.add(const Duration(seconds: 5)),
            );
            connection.startPermitClock.addSample(
              serverTimeUtc: now.add(const Duration(seconds: 5)),
              roundTrip: const Duration(seconds: 10),
            );
          }
          final id = 'uncertain-$sampled';
          final result = connection.requestStartPermit(contextFor(id));
          await waitFor(() =>
              sentOfType(socket, 'assignment.start.permit.request').isNotEmpty);
          socket.controller.add(jsonEncode(envelope(
            'assignment.start.permit.grant',
            id,
            {
              'granted': true,
              'permitId': 'uncertain',
              'expiresAt':
                  now.add(const Duration(seconds: 2)).toIso8601String(),
            },
          )));
          expect(await result, isFalse);
        } finally {
          await connection.close();
        }
      }
    });

    test('clock corrections between sampling and grant cannot change expiry',
        () async {
      for (final correction in [-120, 120]) {
        for (final ttl in [5, 20]) {
          var monotonic = Duration.zero;
          final clock = MonotonicCloudClock(monotonicNow: () => monotonic);
          final (connection, socket) =
              await connected(withClockSample: false, startPermitClock: clock);
          try {
            final serverNow = DateTime.now().toUtc();
            // The telemetry offset retains the local wall clock from sampling.
            // Relative to the wall clock at grant receipt, this models a step
            // in either direction. Permit validation must never read it.
            connection.clockOffset.addSample(
              sentAtUtc: serverNow.subtract(Duration(seconds: correction)),
              serverTimeUtc: serverNow,
              roundTrip: Duration.zero,
            );
            clock.addSample(serverTimeUtc: serverNow, roundTrip: Duration.zero);
            final id = 'correction-$correction-$ttl';
            final result = connection.requestStartPermit(contextFor(id));
            await waitFor(() =>
                sentOfType(socket, 'assignment.start.permit.request')
                    .isNotEmpty);
            // Ten seconds pass while the grant is in flight, independent of
            // the local wall-clock correction represented above.
            monotonic = const Duration(seconds: 10);
            socket.controller.add(jsonEncode(envelope(
              'assignment.start.permit.grant',
              id,
              {
                'granted': true,
                'permitId': 'corrected-clock',
                'expiresAt':
                    serverNow.add(Duration(seconds: ttl)).toIso8601String(),
              },
            )));
            expect(await result, ttl > 10,
                reason: 'wall correction $correction, TTL $ttl');
          } finally {
            await connection.close();
          }
        }
      }
    });

    test('aged clock estimate cannot authorize an otherwise valid grant',
        () async {
      var monotonic = Duration.zero;
      final clock = MonotonicCloudClock(monotonicNow: () => monotonic);
      final (connection, socket) = await connected(startPermitClock: clock);
      try {
        final result = connection.requestStartPermit(contextFor('aged-clock'));
        await waitFor(() =>
            sentOfType(socket, 'assignment.start.permit.request').isNotEmpty);
        monotonic = MonotonicCloudClock.maxSampleAge;
        socket.controller.add(jsonEncode(envelope(
          'assignment.start.permit.grant',
          'aged-clock',
          {
            'granted': true,
            'permitId': 'aged',
            'expiresAt': DateTime.now()
                .toUtc()
                .add(const Duration(minutes: 5))
                .toIso8601String(),
          },
        )));
        expect(await result, isFalse);
      } finally {
        await connection.close();
      }
    });

    test('transport replacement and close invalidate permit time authority',
        () async {
      var socket = FakeSocket();
      final connection = WorkspaceCloudConnection(
        uri: Uri.parse(
            'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-1'),
        workspaceRuntimeId: 'runtime-1',
        workspaceId: 'workspace-1',
        factory: (_) async => socket,
      );
      try {
        await connection.connect();
        await completeHandshake(connection, socket,
            serverTime: DateTime.now().toUtc());
        expect(connection.startPermitClock.latestServerTime, isNotNull);
        socket = FakeSocket();
        await connection.retryNow();
        expect(connection.startPermitClock.latestServerTime, isNull);
        await completeHandshake(connection, socket);
        final result =
            connection.requestStartPermit(contextFor('new-transport'));
        await waitFor(() =>
            sentOfType(socket, 'assignment.start.permit.request').isNotEmpty);
        socket.controller.add(jsonEncode(envelope(
          'assignment.start.permit.grant',
          'new-transport',
          {
            'granted': true,
            'permitId': 'old-sample',
            'expiresAt': DateTime.now()
                .toUtc()
                .add(const Duration(seconds: 30))
                .toIso8601String(),
          },
        )));
        expect(await result, isFalse);
        connection.startPermitClock.addSample(
            serverTimeUtc: DateTime.now().toUtc(), roundTrip: Duration.zero);
      } finally {
        await connection.close();
      }
      expect(connection.startPermitClock.latestServerTime, isNull);
    });

    test('ignores a grant issued for a different attempt', () async {
      final (connection, socket) = await connected();
      final result = connection.requestStartPermit(contextFor('stale-attempt'));
      await waitFor(() =>
          sentOfType(socket, 'assignment.start.permit.request').isNotEmpty);
      socket.controller.add(jsonEncode(envelope(
        'assignment.start.permit.grant',
        'stale-attempt',
        {
          'granted': true,
          'permitId': 'permit-old',
          'expiresAt': DateTime.now()
              .toUtc()
              .add(const Duration(seconds: 30))
              .toIso8601String(),
        },
        attemptId: 'attempt-0',
      )));
      socket.controller.add(jsonEncode(envelope(
        'assignment.start.permit.grant',
        'stale-attempt',
        {'granted': false, 'reason': 'stale'},
      )));
      expect(await result, isFalse);
      await connection.close();
    });

    test('persists a cancel tombstone so a later start never executes',
        () async {
      final directory = await Directory.systemTemp.createTemp('tombstone-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/assignments.jsonl');
      var executions = 0;
      final (connection, socket) = await connected(
        journal: AssignmentJournal(file),
        handler: (_) async {
          executions += 1;
          return const WorkspaceAssignmentResult(summary: 'must not run');
        },
      );
      socket.controller.add(jsonEncode(envelope(
        'assignment.cancel',
        'assignment-early',
        {'reason': 'startup deadline', 'gracePeriodMs': 1000},
      )));
      await waitFor(
          () => sentOfType(socket, 'assignment.cancel.ack').isNotEmpty);
      final record =
          (await AssignmentJournal(file).reconcile())['assignment-early'];
      expect(record?.status, AssignmentStatus.cancelled);
      expect(record?.attemptId, 'attempt-1');
      expect(record?.workspaceId, 'workspace-1');

      socket.controller.add(jsonEncode(envelope(
        'assignment.start',
        'assignment-early',
        {
          'objective': 'inspect',
          'role': 'research',
          'workerId': 'syntila.echo',
          'engineVersion': '1.0.0',
          'profileDefinitionId': 'chatgpt-codex',
          'profileReleaseVersion': 1,
          'input': {},
          'contextArtifactIds': [],
          'timeoutMs': 1000,
        },
      )));
      await waitFor(
          () => sentOfType(socket, 'assignment.cancel.ack').length >= 2);
      expect(executions, 0);
      final replay = sentOfType(socket, 'assignment.cancel.ack').last;
      expect((replay['payload'] as Map)['cancelled'], isTrue);
      await connection.close();
    });

    test('repeated restarts replay lost results and preserve cancellation',
        () async {
      final directory =
          await Directory.systemTemp.createTemp('restart-replay-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/assignments.jsonl');
      var executions = 0;
      final journal = AssignmentJournal(file);
      for (final status in [
        AssignmentStatus.completed,
        AssignmentStatus.cancelled,
        AssignmentStatus.running
      ]) {
        await journal.append(AssignmentRecord(
          assignmentId: status.name,
          status: status,
          updatedAt: DateTime.now().toUtc(),
          workspaceId: 'workspace-1',
          workspaceRuntimeId: 'runtime-1',
          workerId: 'worker-1',
          runId: 'run-1',
          taskId: 'task-1',
          attemptId: 'attempt-1',
          idempotencyKey: 'idem-${status.name}',
          result: status == AssignmentStatus.completed
              ? {
                  'summary': 'durable result',
                  'output': {'text': 'saved'},
                  'artifactIds': <String>[]
                }
              : null,
        ));
      }
      for (var iteration = 0; iteration < 10; iteration++) {
        final reopened = AssignmentJournal(file);
        await reopened.recoverAfterRestart();
        final (connection, socket) = await connected(
          journal: reopened,
          handler: (_) async {
            executions++;
            return const WorkspaceAssignmentResult(summary: 'unexpected');
          },
        );
        try {
          for (final id in ['completed', 'cancelled', 'running']) {
            socket.controller.add(jsonEncode(envelope('assignment.start', id, {
              'objective': 'inspect',
              'role': 'research',
              'workerId': 'syntila.echo',
              'engineVersion': '1.0.0',
              'profileDefinitionId': 'chatgpt-codex',
              'profileReleaseVersion': 1,
              'input': {},
              'contextArtifactIds': [],
              'timeoutMs': 1000,
            })));
          }
          await waitFor(() =>
              sentOfType(socket, 'assignment.result').isNotEmpty &&
              sentOfType(socket, 'assignment.cancel.ack').isNotEmpty &&
              sentOfType(socket, 'assignment.ack')
                  .any((message) => message['assignmentId'] == 'running'));
          final result = sentOfType(socket, 'assignment.result').single;
          expect((result['payload'] as Map)['summary'], 'durable result');
          expect((result['payload'] as Map)['output'], {'text': 'saved'});
          final rejected = sentOfType(socket, 'assignment.ack')
              .singleWhere((message) => message['assignmentId'] == 'running');
          expect((rejected['payload'] as Map)['accepted'], isFalse);
          expect(executions, 0, reason: 'restart $iteration');
          final records = await reopened.reconcile();
          expect(records['completed']!.status, AssignmentStatus.completed);
          expect(records['cancelled']!.status, AssignmentStatus.cancelled);
          expect(
              records['running']!.result?['recoveryState'], 'outcome_unknown');
        } finally {
          // No terminal receipt: the next Service must replay the same result.
          await connection.close();
        }
      }
    });
  });
}
