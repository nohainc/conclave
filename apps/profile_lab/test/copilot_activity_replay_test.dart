import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_profile_lab/utils/profile_activity_mapping_fixtures.dart';

void main() {
  test('bundled Copilot Profile passes the activity mapping replay', () {
    final profile = jsonDecode(
      File('assets/profiles/copilot.json').readAsStringSync(),
    ) as Map<String, Object?>;
    final result = replayProfileActivityMappings(profile);
    expect(result.status, 'passed', reason: result.message);
    expect(result.fixtureName, 'copilot-events/success.jsonl');
  });
}
