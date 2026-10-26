import 'package:conclave_app/src/ax/model_presentation.dart';
import 'package:conclave_design/conclave_design.dart';
import 'package:conclave_protocol/conclave_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ModelPresentation family detection and icon resolution', () {
    test('identifies ChatGPT model from GPT prefix', () {
      final p1 = ModelPresentation.resolve(
        modelId: 'gpt-6.1-sol',
        modelDisplayName: 'GPT-6.1-Sol',
      );
      expect(p1.family, ModelFamily.chatgpt);
      expect(p1.iconAsset, 'assets/worker_icons/chatgpt.png');
      expect(p1.name, 'GPT-6.1-Sol');
      expect(p1.shortName, '6.1-Sol');

      final p2 = ModelPresentation.resolve(
        modelId: 'gpt-6-sol',
        modelDisplayName: 'GPT-6-Sol',
      );
      expect(p2.family, ModelFamily.chatgpt);
      expect(p2.shortName, '6-Sol');
    });

    test('identifies Claude model from Claude prefix', () {
      final p1 = ModelPresentation.resolve(
        modelId: 'claude-3-5-sonnet',
        modelDisplayName: 'Claude 3.5 Sonnet',
      );
      expect(p1.family, ModelFamily.claude);
      expect(p1.iconAsset, 'assets/worker_icons/claude.png');
      expect(p1.name, 'Claude 3.5 Sonnet');
      expect(p1.shortName, '3.5 Sonnet');

      final p2 = ModelPresentation.resolve(
        modelId: 'claude-opus',
        modelDisplayName: 'Claude Opus',
      );
      expect(p2.family, ModelFamily.claude);
      expect(p2.shortName, 'Opus');

      final p3 = ModelPresentation.resolve(
        modelId: 'claude-opus-5-5',
        modelDisplayName: 'Claude Opus 5.5',
      );
      expect(p3.family, ModelFamily.claude);
      expect(p3.shortName, 'Opus 5.5');
    });

    test('identifies Gemini model from Gemini prefix', () {
      final p = ModelPresentation.resolve(
        modelId: 'gemini-3.8-flash',
        modelDisplayName: 'Gemini 3.8 Flash',
      );
      expect(p.family, ModelFamily.gemini);
      expect(p.iconAsset, 'assets/worker_icons/gemini.png');
      expect(p.name, 'Gemini 3.8 Flash');
      expect(p.shortName, '3.8 Flash');
    });

    test('identifies Grok model from Grok prefix and respects brightness', () {
      final p = ModelPresentation.resolve(
        modelId: 'grok-4.7',
        modelDisplayName: 'Grok 4.7',
      );
      expect(p.family, ModelFamily.grok);
      expect(p.iconAsset, 'assets/worker_icons/grok.png');
      expect(p.iconAssetForBrightness(Brightness.light),
          'assets/worker_icons/grok-light.png');
      expect(p.iconAssetForBrightness(Brightness.dark),
          'assets/worker_icons/grok-dark.png');
      expect(p.name, 'Grok 4.7');
      expect(p.shortName, '4.7');
    });

    test(
        'worker using cross-model execution shows model icon instead of worker',
        () {
      // e.g. Copilot or Gemini worker running Claude model
      final p = ModelPresentation.resolve(
        modelId: 'claude-3-5-sonnet',
        modelDisplayName: 'Claude 3.5 Sonnet',
        fallbackWorkerTypeId: 'copilot',
        fallbackWorkerDisplayName: 'Copilot',
      );
      expect(p.family, ModelFamily.claude);
      expect(p.iconAsset, 'assets/worker_icons/claude.png');
      expect(p.shortName, '3.5 Sonnet');
    });

    test('fallback to worker identity when model is unknown or absent', () {
      final p = ModelPresentation.resolve(
        fallbackWorkerTypeId: 'copilot',
        fallbackWorkerDisplayName: 'Copilot',
      );
      expect(p.name, 'Copilot');
      expect(p.iconAsset, 'assets/worker_icons/copilot.png');
      expect(p.iconAssetForBrightness(Brightness.light),
          'assets/worker_icons/copilot-light.png');
      expect(p.iconAssetForBrightness(Brightness.dark),
          'assets/worker_icons/copilot-dark.png');
    });
  });

  group('stripIdentity user-specified examples', () {
    test('strips prefixes matching user examples', () {
      expect(ModelPresentation.stripIdentity('Claude Opus'), 'Opus');
      expect(ModelPresentation.stripIdentity('GPT-6-Sol'), '6-Sol');
      expect(ModelPresentation.stripIdentity('Claude Opus 5.5'), 'Opus 5.5');
      expect(ModelPresentation.stripIdentity('Gemini 3.8 Flash'), '3.8 Flash');
      expect(ModelPresentation.stripIdentity('Grok 4.7'), '4.7');
    });
  });

  group('Widget integration with ModelEffortSelector', () {
    testWidgets(
        'compact composer button displays model icon and short name with effort',
        (tester) async {
      const copilot = WorkerSelectionCapability(
        id: 'copilot-1',
        name: 'GitHub Copilot',
        models: [
          ExecutionModelCapability(
              id: 'claude-3-5-sonnet',
              name: 'Claude 3.5 Sonnet',
              efforts: ['low', 'high']),
          ExecutionModelCapability(
              id: 'gpt-6-sol', name: 'GPT-6-Sol', efforts: ['low', 'medium']),
        ],
      );

      final catalog = const ExecutionSelectionCatalog([copilot]);

      Widget buildSelector(String modelId, String effort) {
        return MaterialApp(
          home: Scaffold(
            body: ModelEffortSelector(
              scope: 'work-composer',
              compact: true,
              showWorkerInCompactSummary: false,
              catalog: catalog,
              value: ExecutionSelection(
                  worker: 'copilot-1', model: modelId, effort: effort),
              modelIconBuilder: (capability, mId, mName) {
                final presentation = ModelPresentation.resolve(
                  modelId: mId,
                  modelDisplayName: mName,
                  fallbackWorkerDisplayName: capability?.name,
                );
                final asset = presentation.iconAsset;
                return asset == null
                    ? const Icon(Icons.smart_toy_outlined)
                    : Image.asset(asset,
                        key: ValueKey('model-asset-$mId'),
                        semanticLabel: '${presentation.name} icon');
              },
              compactModelLabelBuilder: (mId, mName) =>
                  ModelPresentation.stripIdentity(mName ?? mId),
              onChanged: (_) {},
            ),
          ),
        );
      }

      // Test 1: Claude model on Copilot worker
      await tester.pumpWidget(buildSelector('claude-3-5-sonnet', 'high'));
      expect(find.text('3.5 Sonnet · High'), findsOneWidget);
      expect(find.textContaining('Copilot'), findsNothing);
      expect(find.textContaining('Claude 3.5'),
          findsNothing); // Identity prefix stripped
      final claudeImg = tester.widget<Image>(
          find.byKey(const ValueKey('model-asset-claude-3-5-sonnet')));
      expect((claudeImg.image as AssetImage).assetName,
          'assets/worker_icons/claude.png');

      // Test 2: GPT-6-Sol on Copilot worker
      await tester.pumpWidget(buildSelector('gpt-6-sol', 'low'));
      expect(find.text('6-Sol · Low'), findsOneWidget);
      expect(find.textContaining('Copilot'), findsNothing);
      expect(find.textContaining('GPT-6'), findsNothing); // GPT prefix stripped
      final gptImg = tester
          .widget<Image>(find.byKey(const ValueKey('model-asset-gpt-6-sol')));
      expect((gptImg.image as AssetImage).assetName,
          'assets/worker_icons/chatgpt.png');
    });
  });
}
