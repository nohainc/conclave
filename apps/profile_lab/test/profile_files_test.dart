import 'dart:convert';
import 'dart:io';

import 'package:conclave_tool_profile_v1/tool_profile_v1.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final worker in ['chatgpt', 'claude', 'copilot', 'gemini']) {
    test('$worker Profile omits CLI ranges and resolves future versions', () {
      final bytes = File('assets/profiles/$worker.json').readAsBytesSync();
      final profile = EngineProfile.parse(bytes);
      expect(profile.providerTool.containsKey('supportedVersions'), isFalse);
      expect(profile.resolveForProviderVersion('99.0.0').json, profile.json);
      final candidate = LocalDraftProfileCandidate.fromProfileMap(
        jsonDecode(utf8.decode(bytes)) as Map<String, Object?>,
      );
      expect(candidate.logicalWorkerTypeId, worker);
      expect(candidate.payloadDigest, hasLength(64));
    });
  }
}
