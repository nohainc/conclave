import 'package:conclave_profile_lab/utils/provider_version_matrix.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ProviderVersionMatrix', () {
    test(
        'extracts declared bounds and physical test evidence strictly separating supported vs tested',
        () {
      final profile = <String, Object?>{
        'providerTool': {
          'name': 'codex',
          'supportedVersions': [
            {'min': '0.180.0', 'maxExclusive': '0.190.0'}
          ]
        }
      };

      final evidenceList = <Map<String, Object?>>[
        {
          'formatVersion': 2,
          'providerToolVersion': '0.187.2',
          'acceptedAt': '2026-10-03T02:00:00Z',
          'scenarios': {'passive_probe': 'passed'},
        }
      ];

      final matrix = ProviderVersionMatrix.fromProfileAndEvidence(
        profile: profile,
        evidenceList: evidenceList,
      );

      expect(matrix.providerToolName, 'codex');
      expect(matrix.declaredRangeSummary, '0.180.0 – 0.190.0');
      expect(matrix.testedVersions, ['0.187.2']);
      expect(matrix.testedVersionsSummary, '0.187.2');
      expect(matrix.hasTestedVersions, isTrue);
      expect(matrix.distinctionNotice, contains('Supported != Tested'));
      expect(matrix.distinctionNotice, contains('0.180.0 – 0.190.0'));
      expect(matrix.distinctionNotice, contains('0.187.2'));
    });

    test('handles empty test evidence cleanly with untested warning', () {
      final profile = <String, Object?>{
        'providerTool': {
          'name': 'agy',
          'supportedVersions': [
            {'min': '1.0.0', 'maxExclusive': '2.0.0'}
          ]
        }
      };

      final matrix = ProviderVersionMatrix.fromProfileAndEvidence(
        profile: profile,
        evidenceList: [],
      );

      expect(matrix.providerToolName, 'agy');
      expect(matrix.declaredRangeSummary, '1.0.0 – 2.0.0');
      expect(matrix.testedVersions, isEmpty);
      expect(matrix.testedVersionsSummary, 'None tested locally');
      expect(matrix.hasTestedVersions, isFalse);
    });
  });
}
