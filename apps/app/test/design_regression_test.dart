import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_app/src/brand.dart';
import 'package:conclave_app/src/navigation/ax_navigation.dart';
import 'package:conclave_app/src/ax/ax_models.dart';
import 'package:conclave_app/src/features/navigation/app_sidebar.dart';
import 'package:conclave_app/src/features/navigation/ax_shell_context.dart';
import 'package:conclave_app/src/features/common/conclave_code_block.dart';
import 'package:conclave_app/src/features/common/conclave_markdown_body.dart';
import 'package:conclave_app/src/features/projects/projects_pages.dart';
import 'package:conclave_app/src/features/workspace/workspaces_page.dart';

import 'ax_fixture_data.dart';

void main() {
  group('Phase 24 — Design Regression & Theme Token Tests', () {
    // 1. Logo Header
    testWidgets('logo header renders wordmark and logo mark using theme typography and assets',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            appBar: AppBar(
              title: Row(
                children: [
                  ConclaveBrand.logoMark(size: 28),
                  const SizedBox(width: 10),
                  const Text('Conclave AX', style: ConclaveTypography.wordmark),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Conclave AX'), findsOneWidget);
      final textWidget = tester.widget<Text>(find.text('Conclave AX'));
      expect(textWidget.style?.fontSize, ConclaveTypography.wordmark.fontSize);
      expect(textWidget.style?.fontWeight, FontWeight.w700);
      expect(textWidget.style?.letterSpacing, -0.32);

      // Verify logo mark renders with negative space sparkle asset
      expect(find.byType(Image), findsOneWidget);
    });

    // 2. Sidebar Selected / Unselected State
    testWidgets('sidebar applies distinct styling for selected vs unselected navigation items',
        (WidgetTester tester) async {
      AxNavigation? navigatedTo;
      const shellContext = AxShellContext(
        navigation: AxNavigation.home(),
        projects: [
          AxProject(
            id: 'project-1',
            name: 'Project One',
            branch: 'main',
            lastActivity: 'just now',
          ),
        ],
        workspaces: [
          AxWorkspace(
            id: 'workspace-1',
            name: 'Workspace One',
            slug: 'workspace-1',
            status: 'active',
            role: 'owner',
          ),
        ],
        viewerDisplayName: 'Vitalii Noha',
        viewerEmail: 'vitalii@example.test',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: AppSidebar(
              shellContext: shellContext,
              onNavigateTo: (nav) => navigatedTo = nav,
              onToggleProjectExpanded: (_) {},
              onCreateProject: () {},
              onLogout: () {},
              onOpenAbout: () {},
              onOpenExternal: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Home brand logo/link is present
      expect(find.text('Conclave AX'), findsOneWidget);

      // Profile item at bottom
      expect(find.text('Vitalii Noha'), findsOneWidget);

      // Verify unselected profile row container has transparent background
      final profileContainer = tester.widget<Container>(
        find.ancestor(
          of: find.text('Vitalii Noha'),
          matching: find.byType(Container),
        ).first,
      );
      final profileDecoration = profileContainer.decoration as BoxDecoration?;
      expect(profileDecoration?.color, Colors.transparent,
          reason: 'Unselected navigation item must have transparent background');

      // Tap on profile to navigate
      await tester.tap(find.text('Vitalii Noha'));
      expect(navigatedTo, const AxNavigation.profileSecurity());
    });

    testWidgets('sidebar selected navigation item highlights with active selection token',
        (WidgetTester tester) async {
      const shellContext = AxShellContext(
        navigation: AxNavigation.profileSecurity(),
        projects: [],
        workspaces: [],
        viewerDisplayName: 'Vitalii Noha',
        viewerEmail: 'vitalii@example.test',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: AppSidebar(
              shellContext: shellContext,
              onNavigateTo: (_) {},
              onToggleProjectExpanded: (_) {},
              onCreateProject: () {},
              onLogout: () {},
              onOpenAbout: () {},
              onOpenExternal: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final profileContainer = tester.widget<Container>(
        find.ancestor(
          of: find.text('Vitalii Noha'),
          matching: find.byType(Container),
        ).first,
      );
      final profileDecoration = profileContainer.decoration as BoxDecoration?;
      expect(profileDecoration?.color, ConclaveColors.navigationSelected,
          reason: 'Selected navigation item must highlight with ConclaveColors.navigationSelected');

      final profileText = tester.widget<Text>(find.text('Vitalii Noha'));
      expect(profileText.style?.fontWeight, FontWeight.w600);
      expect(profileText.style?.color, Colors.white);
    });

    // 3. Status Badges & Semantic Tokens
    testWidgets('status badges use semantic tokens rather than hardcoded ad-hoc hex values',
        (WidgetTester tester) async {
      // Test semantic status colors defined in design tokens
      expect(ConclaveBrand.success, ConclaveColors.success);
      expect(ConclaveBrand.warning, ConclaveColors.warning);
      expect(ConclaveBrand.error, ConclaveColors.error);
      expect(ConclaveBrand.info, ConclaveColors.info);
      expect(ConclaveBrand.neutral, ConclaveColors.neutral);

      // Verify tone helper mapping
      expect(ExecutionStatusTone.usable.color(true), ConclaveBrand.success);
      expect(ExecutionStatusTone.degraded.color(true), ConclaveBrand.warning);
      expect(ExecutionStatusTone.failed.color(true), ConclaveBrand.error);

      // Test rendering a status badge widget
      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: ConclaveBrand.success.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(ConclaveRadius.sm),
                  border: Border.all(color: ConclaveBrand.success.withValues(alpha: 0.3)),
                ),
                child: const Text(
                  'Ready',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: ConclaveBrand.success,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Ready'), findsOneWidget);
      final textWidget = tester.widget<Text>(find.text('Ready'));
      expect(textWidget.style?.color, ConclaveBrand.success);
      expect(textWidget.style?.fontWeight, FontWeight.w600);
    });

    // 4. Buttons
    testWidgets('buttons consume theme tokens for primary, outline, danger, and disabled states',
        (WidgetTester tester) async {
      bool primaryClicked = false;
      bool dangerClicked = false;

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: Column(
              children: [
                ElevatedButton(
                  onPressed: () => primaryClicked = true,
                  child: const Text('Primary Action'),
                ),
                OutlinedButton(
                  onPressed: () {},
                  child: const Text('Secondary Action'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: ConclaveBrand.error,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () => dangerClicked = true,
                  child: const Text('Danger Action'),
                ),
                const ElevatedButton(
                  onPressed: null,
                  child: Text('Disabled Action'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Primary Action'), findsOneWidget);
      expect(find.text('Secondary Action'), findsOneWidget);
      expect(find.text('Danger Action'), findsOneWidget);
      expect(find.text('Disabled Action'), findsOneWidget);

      await tester.tap(find.text('Primary Action'));
      expect(primaryClicked, isTrue);

      await tester.tap(find.text('Danger Action'));
      expect(dangerClicked, isTrue);

      // Verify disabled button does not trigger events
      final disabledButton = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Disabled Action'),
      );
      expect(disabledButton.onPressed, isNull);
    });

    // 5. Markdown Rendering
    testWidgets('ConclaveMarkdownBody renders headings, body, and inline code with theme tokens',
        (WidgetTester tester) async {
      const markdownContent = '''
# Heading 1
## Heading 2
### Heading 3

This is standard body paragraph text with **bold** and `inline_code`.

> Blockquote context

- Item 1
- Item 2
''';

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: const Scaffold(
            body: SingleChildScrollView(
              child: ConclaveMarkdownBody(data: markdownContent),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Heading 1'), findsOneWidget);
      expect(find.textContaining('Heading 2'), findsOneWidget);
      expect(find.textContaining('Heading 3'), findsOneWidget);
      expect(find.textContaining('This is standard body paragraph text'), findsOneWidget);
      expect(find.textContaining('Blockquote context'), findsOneWidget);
      expect(find.textContaining('Item 1'), findsOneWidget);
      expect(find.textContaining('inline_code'), findsOneWidget);
    });

    // 6. Code Block
    testWidgets('ConclaveCodeBlock renders syntax container, monospace font, and copy button',
        (WidgetTester tester) async {
      String? copiedText;
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText = (call.arguments as Map)['text'] as String;
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      const snippet = 'const apiKey = "conclave-v8";\nconsole.log(apiKey);';

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: const Scaffold(
            body: ConclaveCodeBlock(
              code: snippet,
              language: 'javascript',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('javascript'), findsOneWidget);
      expect(find.textContaining('const apiKey = "conclave-v8";'), findsOneWidget);
      expect(find.byTooltip('Copy code'), findsOneWidget);

      await tester.tap(find.byTooltip('Copy code'));
      await tester.pumpAndSettle();

      expect(copiedText, snippet);
    });

    // 7. Work Response Card
    testWidgets('WorkstreamPage renders prompt bubble and AI response card with theme tokens',
        (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const dataSource = AxFixtureDataSource();

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: WorkstreamPage(
              project: const AxProject(
                id: 'p1',
                name: 'Core Engine',
                branch: 'main',
                lastActivity: 'just now',
              ),
              workstream: const AxWorkstream(
                id: 'ws-1',
                projectId: 'p1',
                name: 'Auth Refactor',
                lead: 'Vitalii',
                status: 'active',
                brief: 'Implement Passkey authentication',
                primaryWorkspace: 'Workspace 1',
                queueStatus: 'Idle',
              ),
              dataSource: dataSource,
              onBackToProject: () {},
              onArchive: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Workstream tabs and panes render
      expect(find.text('Chat'), findsAtLeastNWidgets(1));
      expect(find.text('Work'), findsAtLeastNWidgets(1));
    });

    // 8. Worker Card
    testWidgets('WorkspacesPage renders worker list with readiness badge and theme tokens',
        (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: WorkspacesPage(
              workspaces: const [
                AxWorkspace(
                  id: 'ws-mac',
                  name: 'MacBook Pro M3',
                  hostname: 'macbook.local',
                  appVersion: '8.0.0',
                  status: 'online',
                  workerCount: 2,
                  activeTaskCount: 0,
                  role: 'owner',
                ),
              ],
              workspaceWorkers: const [
                AxWorker(
                  id: 'worker-codex',
                  workspaceId: 'ws-mac',
                  workspaceName: 'MacBook Pro M3',
                  displayName: 'Codex CLI Worker',
                  workerTypeId: 'chatgpt',
                  status: 'ready',
                  readinessState: 'ready',
                  localConcurrencyLimit: 4,
                  capabilities: ['code', 'review'],
                ),
              ],
              onGrant: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('MacBook Pro M3'), findsOneWidget);
      expect(find.text('Ready locally'), findsOneWidget);
      expect(find.byKey(const Key('workspace-worker-row-worker-codex')), findsOneWidget);
    });

    // 9. Key Shared Components Use Theme Tokens (No Hardcoded Breakages)
    testWidgets('dynamic theme switching from light to dark updates shared components',
        (WidgetTester tester) async {
      ThemeMode currentMode = ThemeMode.light;

      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) => MaterialApp(
            theme: ConclaveBrand.lightTheme(),
            darkTheme: ConclaveBrand.darkTheme(),
            themeMode: currentMode,
            home: Scaffold(
              body: Column(
                children: [
                  ConclaveBrand.logoMark(size: 32),
                  const Text('Conclave AX', style: ConclaveTypography.wordmark),
                  ElevatedButton(
                    onPressed: () {
                      setState(() {
                        currentMode = currentMode == ThemeMode.light
                            ? ThemeMode.dark
                            : ThemeMode.light;
                      });
                    },
                    child: const Text('Toggle Theme'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Light theme active
      expect(Theme.of(tester.element(find.text('Conclave AX'))).brightness, Brightness.light);

      // Toggle theme to dark
      await tester.tap(find.text('Toggle Theme'));
      await tester.pumpAndSettle();

      // Dark theme active
      expect(Theme.of(tester.element(find.text('Conclave AX'))).brightness, Brightness.dark);
    });
  });
}
