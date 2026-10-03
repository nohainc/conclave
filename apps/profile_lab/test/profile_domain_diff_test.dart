import 'package:conclave_profile_lab/utils/profile_domain_diff.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ProfileDomainDiffCalculator', () {
    test('computes domain diff between two Tool Profile payloads', () {
      final payloadA = <String, dynamic>{
        'schemaVersion': 1,
        'profileDefinitionId': 'codex-v1',
        'providerTool': {
          'name': 'codex',
          'executableCandidates': ['codex'],
        },
        'execution': {
          'arguments': ['exec', '--model', 'gpt-4o'],
        },
        'sandbox': {
          'mappings': {'restricted': []},
        },
      };

      final payloadB = <String, dynamic>{
        'schemaVersion': 1,
        'profileDefinitionId': 'codex-v1',
        'providerTool': {
          'name': 'codex-v2',
          'executableCandidates': ['codex-cli'],
        },
        'execution': {
          'arguments': ['exec', '--model', 'gpt-4.5-turbo'],
        },
        'sandbox': {
          'mappings': {
            'restricted': ['/var/log']
          },
        },
      };

      final groups =
          ProfileDomainDiffCalculator.computeDiff(payloadA, payloadB);

      expect(groups, hasLength(11));

      final providerToolGroup =
          groups.firstWhere((g) => g.domainName == 'Provider Tool & Discovery');
      expect(providerToolGroup.hasChanges, isTrue);

      final toolNameItem = providerToolGroup.items
          .firstWhere((i) => i.fieldPath == 'providerTool.name');
      expect(toolNameItem.changeType, DiffChangeType.modified);
      expect(toolNameItem.valueA, 'codex');
      expect(toolNameItem.valueB, 'codex-v2');

      final execGroup =
          groups.firstWhere((g) => g.domainName == 'Execution Arguments & I/O');
      expect(execGroup.hasChanges, isTrue);

      final argsItem = execGroup.items
          .firstWhere((i) => i.fieldPath == 'execution.arguments');
      expect(argsItem.changeType, DiffChangeType.modified);
      expect(argsItem.valueA, '["exec","--model","gpt-4o"]');
      expect(argsItem.valueB, '["exec","--model","gpt-4.5-turbo"]');
    });

    test('returns no changes when comparing identical payloads', () {
      final payload = <String, dynamic>{
        'schemaVersion': 1,
        'profileDefinitionId': 'claude-code',
        'providerTool': {'name': 'claude'},
      };

      final groups = ProfileDomainDiffCalculator.computeDiff(payload, payload);
      final changedGroups = groups.where((g) => g.hasChanges);
      expect(changedGroups, isEmpty);
    });
  });
}
