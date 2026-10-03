import 'package:conclave_profile_lab/utils/ai_provenance.dart';
import 'package:conclave_profile_lab/utils/profile_domain_diff.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AiProvenance', () {
    test(
        'serializes and deserializes AI provenance metadata correctly without private conversation logs',
        () {
      const prov = AiProvenance(
        authorType: 'ai_assistant',
        modelIdentifier: 'gemini-2.5-pro',
        parentDigest: 'a1b2c3d4e5f6',
        parentReleaseVersion: 19,
        taskIdentifier: 'passive_probe_fix',
        diffDigest:
            'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        reviewedBy: 'Vitalii',
        actor: 'Vitalii',
      );

      final json = prov.toJson();

      expect(json['authorType'], 'ai_assistant');
      expect(json['modelIdentifier'], 'gemini-2.5-pro');
      expect(json['parentDigest'], 'a1b2c3d4e5f6');
      expect(json['parentReleaseVersion'], 19);
      expect(json['taskIdentifier'], 'passive_probe_fix');
      expect(json['diffDigest'], isNotNull);
      expect(json.containsKey('conversationTranscript'), isFalse);
      expect(json.containsKey('privatePromptHistory'), isFalse);

      final restored = AiProvenance.fromJson(json);
      expect(restored.authorType, 'ai_assistant');
      expect(restored.isAiAssisted, isTrue);
      expect(restored.modelIdentifier, 'gemini-2.5-pro');
      expect(restored.reviewedBy, 'Vitalii');
    });

    test('calculates deterministic diff digest for domain diff groups', () {
      const group = DomainDiffGroup(
        domainName: 'Passive Probe',
        icon: Icons.speed,
        items: [
          DomainDiffItem(
            fieldLabel: 'Command Arguments',
            fieldPath: 'probe.passive.argv',
            valueA: '["--version"]',
            valueB: '["--version", "--json"]',
            changeType: DiffChangeType.modified,
          ),
        ],
      );

      final digest1 = AiProvenance.computeDiffDigest([group]);
      final digest2 = AiProvenance.computeDiffDigest([group]);

      expect(digest1, equals(digest2));
      expect(digest1.length, 64);
    });

    test('formats canonical human-readable audit summary string', () {
      const prov = AiProvenance(
        authorType: 'ai_assistant',
        modelIdentifier: 'gemini-2.5-pro',
        parentDigest: 'a1b2c3d4e5f67890',
        parentReleaseVersion: 19,
        taskIdentifier: 'probe-repair',
        reviewedBy: 'Vitalii',
        actor: 'Vitalii',
      );

      final summary = prov.formatAuditSummary(
        releaseVersion: 20,
        testedProviderVersion: 'Codex 0.188.0',
        publishedBy: 'controlled signer',
        promotedBy: 'Vitalii',
        channel: 'testing',
      );

      expect(
        summary,
        equals(
          'Draft v20 created by AI-assisted change (gemini-2.5-pro, parent: a1b2c3d4), reviewed by Vitalii, tested on Codex 0.188.0, published by controlled signer, promoted to testing by Vitalii.',
        ),
      );
    });

    test('identifies experimental local heuristic provenance accurately', () {
      const provenance = AiProvenance(
        authorType: 'ai_assistant',
        modelIdentifier: 'experimental-local-heuristic',
      );

      final summary = provenance.formatAuditSummary(releaseVersion: 20);

      expect(summary, contains('experimental heuristic suggestion'));
      expect(summary, contains('(experimental-local-heuristic)'));
      expect(summary, isNot(contains('AI-assisted change')));
    });
  });
}
