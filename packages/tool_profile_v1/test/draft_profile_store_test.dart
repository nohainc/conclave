import 'dart:io';

import 'package:conclave_tool_profile_v1/tool_profile_v1.dart';
import 'package:test/test.dart';

import 'tool_profile_release_test.dart';

void main() {
  group('DraftProfileStore', () {
    late Directory tempDir;
    late DraftProfileStore store;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('conclave_lab_drafts_');
      store = DraftProfileStore(draftsRoot: tempDir);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
        'saveDraft validates, persists draft and metadata, and returns unsigned candidate',
        () async {
      final profileMap = validProfileMap(
          profileDefinitionId: 'chatgpt-codex', releaseVersion: 1);

      final candidate = await store.saveDraft(
        profileDefinitionId: 'chatgpt-codex',
        profileJson: profileMap,
        author: 'ai_agent',
        notes: 'Initial draft for testing',
      );

      expect(candidate.isSigned, isFalse);
      expect(candidate.profileDefinitionId, 'chatgpt-codex');
      expect(candidate.releaseVersion, 1);
      expect(candidate.payloadDigest.isNotEmpty, isTrue);

      // Verify files created
      final draftFile = File('${tempDir.path}/chatgpt-codex/draft.json');
      final metaFile =
          File('${tempDir.path}/chatgpt-codex/draft_metadata.json');
      expect(await draftFile.exists(), isTrue);
      expect(await metaFile.exists(), isTrue);

      final metadata = await store.loadDraftMetadata('chatgpt-codex');
      expect(metadata, isNotNull);
      expect(metadata!.author, 'ai_agent');
      expect(metadata.notes, 'Initial draft for testing');
      expect(metadata.lastPayloadDigest, candidate.payloadDigest);
    });

    test('loadDraft loads draft candidate matching payload digest', () async {
      final profileMap = validProfileMap(
          profileDefinitionId: 'gemini-antigravity', releaseVersion: 3);

      final saved = await store.saveDraft(
        profileDefinitionId: 'gemini-antigravity',
        profileJson: profileMap,
      );

      final loaded = await store.loadDraft('gemini-antigravity');
      expect(loaded, isNotNull);
      expect(loaded!.isSigned, isFalse);
      expect(loaded.profileDefinitionId, 'gemini-antigravity');
      expect(loaded.releaseVersion, 3);
      expect(loaded.payloadDigest, saved.payloadDigest);
    });

    test('rejects draft when payload definitionId mismatches requested ID',
        () async {
      final profileMap = validProfileMap(profileDefinitionId: 'chatgpt-codex');

      expect(
        () => store.saveDraft(
          profileDefinitionId: 'other-id',
          profileJson: profileMap,
        ),
        throwsArgumentError,
      );
    });

    test('rejects draft with invalid Tool Profile v1 schema', () async {
      final invalidMap = <String, Object?>{
        'schemaVersion': 1,
        'profileDefinitionId': 'bad-profile',
      };

      expect(
        () => store.saveDraft(
          profileDefinitionId: 'bad-profile',
          profileJson: invalidMap,
        ),
        throwsFormatException,
      );
    });

    test('listDraftDefinitionIds lists all valid drafts in store', () async {
      await store.saveDraft(
        profileDefinitionId: 'profile-a',
        profileJson: validProfileMap(profileDefinitionId: 'profile-a'),
      );
      await store.saveDraft(
        profileDefinitionId: 'profile-b',
        profileJson: validProfileMap(profileDefinitionId: 'profile-b'),
      );

      final list = await store.listDraftDefinitionIds();
      expect(list, ['profile-a', 'profile-b']);
    });

    test(
        'saveEvidence, loadEvidence, and clearEvidence manage test evidence records',
        () async {
      const defId = 'test-profile';
      final draft = await store.saveDraft(
        profileDefinitionId: defId,
        profileJson: validProfileMap(profileDefinitionId: defId),
      );

      final digest1 = draft.payloadDigest;
      final evRecord1 = {
        'evidenceId': 'ev-1',
        'profileDefinitionId': defId,
        'releaseVersion': 10,
        'payloadDigest': digest1,
        'engineVersion': '1.0.0',
        'providerCliVersion': '0.5.0',
        'profileLabVersion': '1.0.0',
        'osVersion': 'macOS 15.0',
        'testType': 'local_passive_probe',
        'normalizedResult': 'pass',
        'issueCodes': <String>[],
      };

      await store.saveEvidence(
        profileDefinitionId: defId,
        payloadDigest: digest1,
        evidenceRecord: evRecord1,
      );

      final loadedEv = await store.loadEvidence(
        profileDefinitionId: defId,
        payloadDigest: digest1,
      );
      expect(loadedEv.length, 1);
      expect(loadedEv.first['evidenceId'], 'ev-1');
      expect(loadedEv.first['payloadDigest'], digest1);

      // Stale evidence cleanup when payload changes
      const digest2 =
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
      await store.saveEvidence(
        profileDefinitionId: defId,
        payloadDigest: digest2,
        evidenceRecord: {'evidenceId': 'ev-2'},
      );

      // Clear evidence while retaining digest2
      await store.clearEvidence(
        profileDefinitionId: defId,
        retainPayloadDigest: digest2,
      );

      expect(
          await store.loadEvidence(
              profileDefinitionId: defId, payloadDigest: digest1),
          isEmpty);
      final remaining = await store.loadEvidence(
          profileDefinitionId: defId, payloadDigest: digest2);
      expect(remaining.length, 1);
    });

    test('deleteDraft cleans up draft directory entirely', () async {
      const defId = 'delete-me';
      await store.saveDraft(
        profileDefinitionId: defId,
        profileJson: validProfileMap(profileDefinitionId: defId),
      );

      expect(await store.deleteDraft(defId), isTrue);
      expect(await store.loadDraft(defId), isNull);
      expect(await store.listDraftDefinitionIds(), isEmpty);
    });

    test(
        'LocalDraftProfileCandidate security boundary against ToolProfileReleaseAdmission',
        () async {
      final draft = await store.saveDraft(
        profileDefinitionId: 'chatgpt-codex',
        profileJson: validProfileMap(profileDefinitionId: 'chatgpt-codex'),
      );

      // Draft candidate implements ToolProfileCandidate, but is not signed
      expect(draft.isSigned, isFalse);
      expect(draft is ToolProfileReleaseAdmission, isFalse);
    });
  });
}
