import 'dart:convert';
import 'dart:io';
import 'package:conclave_cli_worker_engine/src/engine_session_store.dart';
import 'package:test/test.dart';

void main() {
  test(
    'same scope is exclusive while independent workers and release remain available',
    () async {
      final root = await Directory.systemTemp.createTemp('session-lease-');
      addTearDown(() => root.delete(recursive: true));
      Future<EngineSessionLease> acquire(String worker) =>
          EngineSessionStore(root).acquireExecution(
            sessionKey: 'scope',
            workerTypeId: worker,
            profileDefinitionId: 'profile',
            providerToolIdentity: 'tool',
          );
      final first = await acquire('fixture');
      try {
        await expectLater(
          acquire('fixture'),
          throwsA(isA<EngineSessionBusy>()),
        );
        final otherWorker = await acquire('other');
        await otherWorker.release();
      } finally {
        await first.release();
      }
      final restarted = await acquire('fixture');
      await restarted.release();
      await restarted.release();
    },
  );

  test(
    'process locks refuse concurrent native use and release after a crash',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'session-process-lock-',
      );
      addTearDown(() => root.delete(recursive: true));
      final helper =
          '${Directory.current.path}/test/helpers/session_lock_process.dart';
      final holder = await Process.start(Platform.resolvedExecutable, [
        helper,
        root.path,
        'scope',
        'hold',
      ]);
      addTearDown(() {
        holder.kill(ProcessSignal.sigkill);
      });
      expect(
        await holder.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first
            .timeout(const Duration(seconds: 10)),
        'acquired',
      );
      final blocked = await Process.run(Platform.resolvedExecutable, [
        helper,
        root.path,
        'scope',
        'release',
      ]);
      expect(blocked.exitCode, 0, reason: blocked.stderr.toString());
      expect(blocked.stdout.toString().trim(), 'busy');
      final independent = await Process.run(Platform.resolvedExecutable, [
        helper,
        root.path,
        'another-scope',
        'release',
      ]);
      expect(independent.stdout.toString().trim(), 'acquired');
      holder.kill(ProcessSignal.sigkill);
      await holder.exitCode;
      final afterCrash = await Process.run(Platform.resolvedExecutable, [
        helper,
        root.path,
        'scope',
        'release',
      ]);
      expect(afterCrash.exitCode, 0, reason: afterCrash.stderr.toString());
      expect(afterCrash.stdout.toString().trim(), 'acquired');
    },
  );
}
