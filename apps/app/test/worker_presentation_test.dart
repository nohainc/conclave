import 'package:conclave_app/src/ax/worker_presentation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
  });
}
