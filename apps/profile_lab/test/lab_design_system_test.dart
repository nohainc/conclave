import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:conclave_profile_lab/app.dart';
import 'package:conclave_profile_lab/controllers/profile_lab_controller.dart';
import 'package:conclave_profile_lab/profile_admin_api_client.dart';
import 'package:conclave_profile_lab/profile_lab_auth.dart';
import 'package:conclave_profile_lab/profile_lab_paths.dart';
import 'package:conclave_profile_lab/profile_lab_session_store.dart';
import 'package:conclave_profile_lab/theme/profile_lab_theme.dart';
import 'package:conclave_profile_lab/widgets/lab_components.dart';
import 'package:conclave_profile_lab/widgets/lab_shortcuts.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Controller extends ProfileLabController {
  _Controller(ProfileLabPaths paths)
      : super(
            paths: paths,
            sessionStore: ProfileLabSessionStore.inMemoryForTesting(paths));
  int saves = 0,
      catalog = 0,
      releases = 0,
      workspaces = 0,
      activity = 0,
      draftRefresh = 0;
  @override
  Future<void> ensureAreaData(LabArea tab) async {}
  @override
  Future<void> saveCurrentDraft(
      {String author = 'developer', String notes = ''}) async {
    saves++;
    isDirty = false;
  }

  @override
  Future<void> fetchCloudCatalog() async {
    catalog++;
  }

  @override
  Future<void> fetchCloudReleases([String? profileDefinitionId]) async {
    releases++;
  }

  @override
  Future<void> fetchWorkspaceChannels() async {
    workspaces++;
  }

  @override
  Future<void> fetchCloudAudit({bool? definitionOnly}) async {
    activity++;
  }

  @override
  Future<void> refreshEvidence() async {
    draftRefresh++;
  }
}

void main() {
  setUpAll(() async {
    if (const bool.fromEnvironment('LAB_CAPTURE')) {
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
      for (final entry in {
        '-apple-system': '/System/Library/Fonts/SFNS.ttf',
        'Menlo': '/System/Library/Fonts/Menlo.ttc'
      }.entries) {
        if (!File(entry.value).existsSync()) continue;
        final loader = FontLoader(entry.key)
          ..addFont(File(entry.value)
              .readAsBytes()
              .then((bytes) => ByteData.sublistView(bytes)));
        await loader.load();
      }
    }
  });
  late Directory temp;
  late _Controller c;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('lab_design_');
    c = _Controller(ProfileLabPaths(homeDirectory: temp.path));
    c.labAccess = ProfileLabAccessReadModel.fromJson({
      'permissions': {'profilesAdmin': true, 'releaseManager': true},
      'signer': {'ready': false},
    });
    c.currentSession = ProfileLabSession(
        credential: 'test',
        sessionId: 'test-session',
        userId: 'user',
        displayName: 'Operator',
        email: 'operator@example.invalid',
        expiresAt: DateTime.now().add(const Duration(hours: 1)));
    final payload = jsonDecode(await File(
            '../../packages/tool-profile/test/fixtures/chatgpt-codex.v1.json')
        .readAsString()) as Map<String, dynamic>;
    c.currentDraft = await c.store
        .saveDraft(profileDefinitionId: 'chatgpt-codex', profileJson: payload);
    c.selectedDefinitionId = 'chatgpt-codex';
    c.currentJsonText = jsonEncode(payload);
    c.cloudWorkers = [
      {
        'workerTypeId': 'chatgpt',
        'displayName': 'ChatGPT',
        'profileDefinitionId': 'chatgpt-codex',
        'providerToolName': 'codex',
        'releaseStage': 'stable'
      }
    ];
    c.selectedCloudWorker = c.cloudWorkers.first;
    c.selectedCloudDefinition = {
      'channels': {'testing': 1, 'beta': null, 'stable': null}
    };
    c.cloudReleases = [
      {
        'profileDefinitionId': 'chatgpt-codex',
        'releaseVersion': 1,
        'lifecycleState': 'testing',
        'profile': payload,
        'publishedAt': '2026-10-05',
        'payloadDigest': c.currentDraft!.payloadDigest
      }
    ];
    c.selectedCloudRelease = c.cloudReleases.first;
    c.workspaceChannels = [
      {
        'id': 'ws-1',
        'name': 'Test Mac',
        'hostname': 'test-mac.local',
        'appVersion': '0.8.2',
        'status': 'online',
        'channel': 'testing'
      }
    ];
    c.cloudAuditEvents = [
      {
        'id': 'event',
        'profileDefinitionId': 'chatgpt-codex',
        'releaseVersion': 1,
        'action': 'published_for_testing',
        'createdAt': '2026-10-05',
        'actorDisplayName': 'Operator'
      }
    ];
  });
  tearDown(() async {
    c.dispose();
    await temp.delete(recursive: true);
  });
  Future<void> key(WidgetTester t, LogicalKeyboardKey key) async {
    await t.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await t.sendKeyEvent(key);
    await t.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await t.pump();
  }

  testWidgets(
      'Command shortcuts respect active resource, editor focus and dialog boundaries',
      (t) async {
    c.workerSubView = WorkerSubView.draftAndTest;
    c.isDirty = true;
    late BuildContext page;
    await t.pumpWidget(MaterialApp(home: Builder(builder: (context) {
      page = context;
      return Scaffold(
          body: LabShortcuts(
              controller: c, child: const TextField(autofocus: true)));
    })));
    await t.pump();
    await key(t, LogicalKeyboardKey.keyS);
    expect(c.saves, 1);
    await key(t, LogicalKeyboardKey.keyS);
    expect(c.saves, 1);
    c.isDirty = true;
    c.jsonValidationError = 'Invalid JSON';
    await key(t, LogicalKeyboardKey.keyS);
    expect(c.saves, 1);
    c.jsonValidationError = null;
    c.isTesting = true;
    await key(t, LogicalKeyboardKey.keyS);
    expect(c.saves, 1);
    c.isTesting = false;
    await key(t, LogicalKeyboardKey.keyR);
    expect(c.draftRefresh, 1);
    c.workerSubView = WorkerSubView.releases;
    await key(t, LogicalKeyboardKey.keyR);
    expect(c.releases, 1);
    c.workerSubView = WorkerSubView.overview;
    await key(t, LogicalKeyboardKey.keyR);
    expect(c.catalog, 1);
    c.selectedArea = LabArea.workspaces;
    await key(t, LogicalKeyboardKey.keyR);
    expect(c.workspaces, 1);
    c.selectedArea = LabArea.audit;
    await key(t, LogicalKeyboardKey.keyR);
    expect(c.activity, 1);
    showDialog<void>(
        context: page,
        builder: (_) => const AlertDialog(title: Text('Confirmation')));
    await t.pumpAndSettle();
    await key(t, LogicalKeyboardKey.keyR);
    expect(c.activity, 1);
    expect(t.takeException(), isNull);
  });
  for (final size in [const Size(800, 700), const Size(1440, 1000)]) {
    testWidgets('all primary views fit ${size.width}×${size.height}',
        (t) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      for (final view in WorkerSubView.values) {
        c.selectedArea = LabArea.workers;
        c.workerSubView = view;
        await t.pumpWidget(RepaintBoundary(
            key: const ValueKey('capture'),
            child:
                ProfileLabApp(key: ValueKey('workers-$view'), controller: c)));
        await t.pump();
        expect(t.takeException(), isNull, reason: 'Worker $view at $size');
        expect(find.text('ChatGPT'), findsWidgets);
        if (const bool.fromEnvironment('LAB_CAPTURE')) {
          await t.pump();
          final boundary = t.renderObject<RenderRepaintBoundary>(
              find.byKey(const ValueKey('capture')));
          await t.runAsync(() async {
            final image = await boundary.toImage();
            final bytes =
                await image.toByteData(format: ui.ImageByteFormat.png);
            await File(
                    '/tmp/profile-lab-${size.width.toInt()}-${view.name}.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
      }
      for (final tab in [LabArea.workspaces, LabArea.audit]) {
        c.selectedArea = tab;
        await t.pumpWidget(ProfileLabApp(key: ValueKey(tab), controller: c));
        await t.pump();
        expect(t.takeException(), isNull, reason: '$tab at $size');
      }
    });
  }
  testWidgets('semantic states and lifecycle progress have readable labels',
      (t) async {
    final semantics = t.ensureSemantics();

    await t.pumpWidget(MaterialApp(
        theme: ProfileLabTheme.darkTheme,
        home: Scaffold(
            body: ListView(children: const [
          StatusBadge(label: 'Saved locally', status: LabStatus.success),
          StatusBadge(label: 'Version unsupported', status: LabStatus.warning),
          StatusBadge(label: 'Test failed', status: LabStatus.error),
          LifecycleStepper(steps: [
            LabLifecycleStep('Configure', isDone: true),
            LabLifecycleStep('Test', isActive: true),
            LabLifecycleStep('Sync')
          ]),
          OperationProgress(label: 'Loading releases'),
          TechnicalInspector(children: [Text('Hidden identity')])
        ]))));
    expect(find.bySemanticsLabel('Saved locally'), findsOneWidget);
    expect(find.bySemanticsLabel('Test: Current step'), findsOneWidget);
    expect(find.bySemanticsLabel('Sync: Pending'), findsOneWidget);
    expect(find.text('Hidden identity'), findsNothing);
    expect(t.takeException(), isNull);
    await expectLater(t, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(t, meetsGuideline(textContrastGuideline));
    semantics.dispose();
  });
}
