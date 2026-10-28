import 'package:syntila_app/src/ax/worker_presentation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('monochrome marks follow the surface brightness', () {
    for (final worker in ['copilot', 'grok']) {
      final presentation = WorkerPresentation.resolve(worker, '');
      expect(presentation.iconAssetForBrightness(Brightness.light),
          'assets/worker_icons/$worker-light.png');
      expect(presentation.iconAssetForBrightness(Brightness.dark),
          'assets/worker_icons/$worker-dark.png');
    }
    expect(
        WorkerPresentation.resolve('claude', '')
            .iconAssetForBrightness(Brightness.dark),
        'assets/worker_icons/claude.png');
    expect(
        WorkerPresentation.resolve('unknown', '')
            .iconAssetForBrightness(Brightness.dark),
        isNull);
  });

  test(
      'catalog names override branding and new workers have a generic fallback',
      () {
    final custom = WorkerPresentation.resolve('future-worker', 'Researcher');
    expect(custom.name, 'Researcher');
    expect(custom.iconAsset, isNull);
    expect(WorkerPresentation.resolve(null, null).name, 'Worker');
    final chat = WorkerPresentation.resolve(' ChatGPT ', 'My worker');
    expect(chat.name, 'My worker');
    expect(chat.iconAsset, 'assets/worker_icons/chatgpt.png');
    expect(WorkerPresentation.resolve('gemini', '').name, 'Gemini');
    expect(WorkerPresentation.resolve('claude', '').iconAsset,
        'assets/worker_icons/claude.png');
    final copilot = WorkerPresentation.resolve('copilot', '');
    expect(copilot.name, 'Copilot');
    expect(copilot.iconAsset, 'assets/worker_icons/copilot.png');
    final grok = WorkerPresentation.resolve('grok', '');
    expect(grok.name, 'Grok');
    expect(grok.iconAsset, 'assets/worker_icons/grok.png');
    expect(WorkerPresentation.resolve('custom', 'Claude Code').iconAsset,
        'assets/worker_icons/claude.png');
    expect(
        WorkerPresentation.resolve('custom', 'Codex Worker',
                profileDefinitionId: 'chatgpt-codex', providerToolName: 'codex')
            .iconAsset,
        'assets/worker_icons/chatgpt.png');
    expect(
        WorkerPresentation.resolve('custom', 'Antigravity CLI',
                profileDefinitionId: 'gemini-antigravity',
                providerToolName: 'agy')
            .iconAsset,
        'assets/worker_icons/gemini.png');
  });
}
