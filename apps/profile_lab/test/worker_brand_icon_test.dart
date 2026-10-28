import 'package:syntila_profile_lab/widgets/worker_brand_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final worker in ['copilot', 'grok']) {
    testWidgets('$worker follows live theme changes', (tester) async {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: WorkerBrandIcon(workerTypeId: worker, name: worker),
        ));
        await tester.pumpAndSettle();
        final image = tester.widget<Image>(find.byType(Image));
        final theme = brightness == Brightness.dark ? 'dark' : 'light';
        expect((image.image as AssetImage).assetName,
            'assets/worker_icons/$worker-$theme.png');
        expect(tester.takeException(), isNull);
      }
    });
  }

  test('maps Worker type, Profile, or provider tool to a provider mark', () {
    expect(workerBrandIconAsset(workerTypeId: 'chatgpt'),
        'assets/worker_icons/chatgpt.png');
    expect(workerBrandIconAsset(workerTypeId: 'x', providerToolName: 'codex'),
        'assets/worker_icons/chatgpt.png');
    expect(
        workerBrandIconAsset(
            workerTypeId: 'x', profileDefinitionId: 'anthropic.claude-code'),
        'assets/worker_icons/claude.png');
    expect(workerBrandIconAsset(workerTypeId: 'gemini'),
        'assets/worker_icons/gemini.png');
    expect(
        workerBrandIconAsset(
            workerTypeId: 'copilot',
            profileDefinitionId: 'copilot-cli',
            providerToolName: 'copilot'),
        'assets/worker_icons/copilot-light.png');
    expect(
        workerBrandIconAsset(
            workerTypeId: 'grok',
            profileDefinitionId: 'grok-cli',
            providerToolName: 'grok'),
        'assets/worker_icons/grok-light.png');
  });

  test('unknown Workers have no provider mark', () {
    expect(workerBrandIconAsset(workerTypeId: 'internal-tool'), isNull);
  });

  testWidgets('unknown Workers show their initial', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: WorkerBrandIcon(workerTypeId: 'internal-tool', name: 'internal'),
    ));
    expect(find.text('I'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('bundled provider marks load', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Row(children: [
        WorkerBrandIcon(workerTypeId: 'chatgpt', name: 'ChatGPT'),
        WorkerBrandIcon(workerTypeId: 'claude', name: 'Claude'),
        WorkerBrandIcon(workerTypeId: 'gemini', name: 'Gemini'),
        WorkerBrandIcon(workerTypeId: 'grok', name: 'Grok'),
      ]),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNWidgets(4));
    expect(tester.takeException(), isNull);
  });
}
