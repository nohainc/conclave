import 'package:conclave_app/src/features/common/dictation/speech_dictation.dart';
import 'package:conclave_app/src/features/common/markdown_composer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeDictation implements SpeechDictation {
  _FakeDictation({this.supported = true});

  @override
  final bool supported;
  void Function(String transcript)? onTranscript;
  void Function(String? error)? onEnd;
  var stopped = 0;

  @override
  void start({
    required void Function(String transcript) onTranscript,
    required void Function(String? error) onEnd,
  }) {
    this.onTranscript = onTranscript;
    this.onEnd = onEnd;
  }

  @override
  void stop() => stopped++;
}

void main() {
  Future<void> pump(WidgetTester tester, TextEditingController controller,
          SpeechDictation dictation,
          {bool twoRowLayout = false}) =>
      tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MarkdownComposer(
          controller: controller,
          chatStyle: true,
          twoRowLayout: twoRowLayout,
          dictation: dictation,
          onSend: () {},
        )),
      ));

  testWidgets('hides the mic when speech recognition is unsupported',
      (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await pump(tester, controller, _FakeDictation(supported: false));
    expect(find.byKey(const ValueKey('composer-dictation')), findsNothing);
  });

  for (final twoRowLayout in [false, true]) {
    testWidgets('dictates at the cursor twoRowLayout=$twoRowLayout',
        (tester) async {
      final controller = TextEditingController(text: 'Hello world');
      addTearDown(controller.dispose);
      controller.selection = const TextSelection.collapsed(offset: 5);
      final dictation = _FakeDictation();
      await pump(tester, controller, dictation, twoRowLayout: twoRowLayout);

      await tester.tap(find.byTooltip('Dictate'));
      await tester.pump();
      expect(find.byTooltip('Stop dictation'), findsOneWidget);

      dictation.onTranscript!('there');
      expect(controller.text, 'Hello there world');
      // Interim results are replaced by the growing session transcript.
      dictation.onTranscript!('there my');
      dictation.onTranscript!('there my friend');
      expect(controller.text, 'Hello there my friend world');
      expect(controller.selection.baseOffset, 'Hello there my friend'.length);

      dictation.onEnd!(null);
      await tester.pump();
      expect(find.byTooltip('Dictate'), findsOneWidget);
    });
  }

  testWidgets('clearing the input (send) ends dictation', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final dictation = _FakeDictation();
    await pump(tester, controller, dictation);

    await tester.tap(find.byTooltip('Dictate'));
    await tester.pump();
    dictation.onTranscript!('ship it');
    expect(controller.text, 'ship it');
    controller.clear();
    await tester.pump();
    expect(dictation.stopped, 1);
    dictation.onTranscript!('ship it now');
    expect(controller.text, isEmpty);
    expect(find.byTooltip('Dictate'), findsOneWidget);
  });

  testWidgets('reports blocked microphone access', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final dictation = _FakeDictation();
    await pump(tester, controller, dictation);

    await tester.tap(find.byTooltip('Dictate'));
    await tester.pump();
    dictation.onEnd!('not-allowed');
    await tester.pump();
    expect(find.textContaining('Microphone access is blocked'), findsOneWidget);
  });
}
