import 'dart:io';

import 'package:conclave_profile_lab/controllers/profile_lab_controller.dart';
import 'package:conclave_profile_lab/profile_lab_paths.dart';
import 'package:conclave_profile_lab/profile_lab_session_store.dart';
import 'package:conclave_profile_lab/views/promotion_gate_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PromotionGateDialog', () {
    late Directory temp;
    late ProfileLabPaths paths;
    late ProfileLabController controller;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('gate_dialog_test_');
      paths = ProfileLabPaths(homeDirectory: temp.path);
      controller = ProfileLabController(
        paths: paths,
        sessionStore: ProfileLabSessionStore.inMemoryForTesting(paths),
      );
      await controller.initialize();
    });

    tearDown(() async {
      await temp.delete(recursive: true);
    });

    testWidgets('renders promotion gate evidence checklist items',
        (tester) async {
      final releasePayload = {
        'schemaVersion': 1,
        'profileDefinitionId': 'test-worker-profile',
        'releaseVersion': 1,
        'logicalWorkerTypeId': 'test-worker',
        'engineFamily': 'cli',
        'engineCompatibility': {'min': '1.0.0', 'maxExclusive': '2.0.0'},
        'providerTool': {
          'name': 'testtool',
          'executableCandidates': ['testtool'],
          'discovery': {'standardLocations': [], 'allowPathSearch': true},
          'versionProbe': {
            'arguments': ['--version'],
            'timeoutMs': 10000,
            'source': 'stdout',
            'extract': {'kind': 'regex_capture', 'patternId': 'semver'}
          },
          'supportedVersions': [
            {'min': '1.2.3', 'maxExclusive': '1.3.0'}
          ],
        },
        'environment': {
          'passthrough': ['PATH', 'HOME'],
          'set': {}
        },
        'probe': {
          'passive': {
            'checks': [
              {
                'id': 'auth',
                'arguments': ['--version'],
                'timeoutMs': 5000,
                'successExitCodes': [0],
                'failureIssueCode': 'provider_authentication_required'
              }
            ],
            'configChecks': []
          }
        },
        'execution': {
          'arguments': ['run', '{{prompt}}'],
          'stdin': {'mode': 'raw_text', 'value': '{{prompt}}'},
          'output': {'mode': 'plain_text'},
          'events': []
        },
        'session': {
          'supported': false,
          'formatId': 'session-v1',
          'compatibleFormatIds': ['session-v1'],
          'resumeArguments': [],
          'requireObservedIdMatch': false
        },
        'model': {
          'supported': false,
          'arguments': [],
          'unknownModelPolicy': 'pass_through'
        },
        'timeout': {'providerArguments': [], 'providerReserveMs': 0},
        'sandbox': {
          'mappings': {
            'restricted': [],
            'provider_default': [],
            'full_access': []
          }
        },
        'progress': [],
        'errors': {
          'mappings': [
            {
              'evidence': {'kind': 'exit_code', 'value': 2},
              'issueCode': 'provider_failure'
            }
          ]
        },
        'capabilities': ['text'],
        'compatibilityOverrides': []
      };

      final releaseRecord = {
        'releaseVersion': 1,
        'profileDefinitionId': 'test-worker-profile',
        'workerTypeId': 'test-worker',
        'lifecycleState': 'testing',
        'signature': 'test-ed25519-signature-string',
        'signingKeyId': 'profile-key-v1',
        'payloadDigest': 'a'.padRight(64, '0'),
        'profile': releasePayload,
      };

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () => PromotionGateDialog.show(
                  context: ctx,
                  controller: controller,
                  release: releaseRecord,
                  targetChannel: 'beta',
                ),
                child: const Text('Open Gate Dialog'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Gate Dialog'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Promotion Gate Checklist: v1 → BETA'),
          findsOneWidget);
      expect(find.text('Ed25519 Signature Validity'), findsOneWidget);
      expect(find.text('Tool Profile v1 Schema Validity'), findsOneWidget);
      expect(find.text('Logical Worker Identity Consistency'), findsOneWidget);
      expect(find.text('CLI Worker Engine Compatibility'), findsOneWidget);
    });
  });
}
