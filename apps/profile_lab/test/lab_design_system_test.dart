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
  int saves = 0, catalog = 0, draftRefresh = 0;
  @override
  Future<void> ensureWorkerCatalog() async {}
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
        'Inter': '/System/Library/Fonts/SFNS.ttf',
        'Menlo': '/System/Library/Fonts/Menlo.ttc',
        'JetBrains Mono': '/System/Library/Fonts/Menlo.ttc',
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
    c = _Controller(ProfileLabPaths(
        homeDirectory: temp.path,
        repositoryRoot: Directory('${temp.path}/repo')));
    c.labAccess = ProfileLabAccessReadModel.fromJson({
      'permissions': {'profilesAdmin': true},
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
        'currentRevision': 1,
        'currentDigest': 'digest-1'
      }
    ];
    c.selectedCloudWorker = c.cloudWorkers.first;
    c.selectedCloudDefinition = {
      'profileDefinitionId': 'chatgpt-codex',
      'displayName': 'ChatGPT',
      'providerToolName': 'codex',
      'status': 'current',
    };
    c.currentProfileRevision = 1;
    c.currentProfileDigest = c.currentDraft!.payloadDigest;
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
    await key(t, LogicalKeyboardKey.keyR);
    expect(c.draftRefresh, 2);
    c.currentDraft = null;
    await key(t, LogicalKeyboardKey.keyR);
    expect(c.catalog, 1);
    showDialog<void>(
        context: page,
        builder: (_) => const AlertDialog(title: Text('Confirmation')));
    await t.pumpAndSettle();
    await key(t, LogicalKeyboardKey.keyR);
    expect(c.catalog, 1);
    expect(t.takeException(), isNull);
  });
  for (final size in [const Size(800, 700), const Size(1440, 1000)]) {
    testWidgets('all primary views fit ${size.width}×${size.height}',
        (t) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await t.pumpWidget(RepaintBoundary(
          key: const ValueKey('capture'),
          child: ProfileLabApp(key: const ValueKey('workers'), controller: c)));
      await t.pump();
      expect(t.takeException(), isNull, reason: 'Workers at $size');
      expect(find.text('ChatGPT'), findsWidgets);
      if (const bool.fromEnvironment('LAB_CAPTURE')) {
        await t.pump();
        final boundary = t.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('capture')));
        await t.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('/tmp/profile-lab-${size.width.toInt()}-workers.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
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
          OperationProgress(label: 'Loading Worker catalog')
        ]))));
    expect(find.bySemanticsLabel('Saved locally'), findsOneWidget);
    expect(find.text('Loading Worker catalog'), findsOneWidget);
    expect(t.takeException(), isNull);
    await expectLater(t, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(t, meetsGuideline(textContrastGuideline));
    semantics.dispose();
  });
}
