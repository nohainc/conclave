import 'package:conclave_workspace/worker_brand_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
        'assets/worker_icons/copilot.png');
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
      ]),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });
}
