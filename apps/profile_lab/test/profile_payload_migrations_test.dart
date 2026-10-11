import 'dart:convert';
import 'dart:io';

import 'package:conclave_profile_lab/utils/profile_payload_migrations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('migrates legacy ChatGPT TSV discovery to app-server discovery',
      () async {
    final profile = Map<String, Object?>.from(jsonDecode(await File(
      '../../packages/tool-profile/test/fixtures/chatgpt-codex.v2.json',
    ).readAsString()) as Map);
    final migrated = migrateProfilePayload(profile);

    expect(migrated, isNotNull);
    final model = migrated!['model'] as Map;
    expect(model['unknownModelPolicy'], 'pass_through');
    expect(model.containsKey('catalog'), isFalse);
    expect(model.containsKey('allowlist'), isFalse);
    expect(model.containsKey('supportedReasoningEfforts'), isFalse);
    expect(model['discovery'], {
      'schemaVersion': 1,
      'arguments': ['app-server', '--listen', 'stdio://'],
      'timeoutMs': 10000,
      'format': 'codex_app_server',
      'idPrefix': '',
    });
    expect((profile['model'] as Map)['discovery'],
        isNot((migrated['model'] as Map)['discovery']));
  });

  test('leaves current profiles and other providers unchanged', () {
    final current = <String, Object?>{
      'profileDefinitionId': 'chatgpt-codex',
      'logicalWorkerTypeId': 'chatgpt',
      'model': {
        'discovery': {'format': 'codex_app_server'},
      },
    };
    final other = <String, Object?>{
      'profileDefinitionId': 'gemini-antigravity',
      'logicalWorkerTypeId': 'gemini',
      'model': {
        'discovery': {'format': 'tsv'},
      },
    };

    expect(migrateProfilePayload(current), isNull);
    expect(migrateProfilePayload(other), isNull);
  });
}
