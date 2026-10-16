import 'dart:io';

import 'package:conclave_tool_profile_v1/tool_profile_v1.dart';
import 'package:conclave_workspace/worker_profile_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/worker_profile_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temporary;
  late WorkerProfileStore workspaceStore;
  late WorkerTrustPolicy trustPolicy;

  setUp(() async {
    temporary =
        await Directory.systemTemp.createTemp('workspace_unsigned_test_');
    trustPolicy = WorkerTrustPolicy(trustedPublicKeys: {});
    workspaceStore = WorkerProfileStore(
      profilesRoot: Directory('${temporary.path}/Profiles'),
      trustPolicy: trustPolicy,
    );
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  group('Phase 27 — Security Boundary: Unsigned Profile Lab Draft Isolation',
      () {
    test(
        'Unsigned Profile Lab draft candidate is explicitly rejected by Workspace trusted Profile store',
        () async {
      final draftPayload = buildTestWorkerProfile(
        profileDefinitionId: 'codex-cli',
        logicalWorkerTypeId: 'codex',
        providerToolName: 'codex',
        executableCandidates: ['codex'],
      );

      // Profile Lab candidate (unsigned)
      final candidate = LocalDraftProfileCandidate.fromProfileMap(draftPayload);
      expect(candidate.isPublished, isFalse);

      // Workspace execution storage must reject the unsigned candidate.
      expect(
        () => workspaceStore.executionProfileFile(candidate),
        throwsStateError,
      );

      expect(
        await workspaceStore
            .currentWorkerProfile(candidate.logicalWorkerTypeId),
        isNull,
      );
    });
  });
}
