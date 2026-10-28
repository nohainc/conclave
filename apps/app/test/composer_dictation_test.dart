import 'package:syntila_app/src/features/common/dictation/speech_dictation.dart';
import 'package:syntila_app/src/features/common/markdown_composer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeDictation implements SpeechDictation {
  _FakeDictation({this.supported = true});

  @override
  final bool supported;
  void Function(String transcript)? onTranscript;
  void Function(String? error)? onEnd;
  var stopped = 0;
  String? startedLanguage;

  @override
  String get browserLanguage => 'en-US';

  @override
  String? preferredLanguage;

  @override
  void start({
    required String language,
    required void Function(String transcript) onTranscript,
    required void Function(String? error) onEnd,
  }) {
    startedLanguage = language;
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

  testWidgets('language and mic share an outline that turns red when live',
      (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await pump(tester, controller, _FakeDictation());
    Color border() => ((tester
                .widget<Container>(
                    find.byKey(const ValueKey('composer-dictation-group')))
                .decoration as BoxDecoration)
            .border as Border)
        .top
        .color;
    final group = find.byKey(const ValueKey('composer-dictation-group'));
    expect(
        find.descendant(
            of: group,
            matching:
                find.byKey(const ValueKey('composer-dictation-language'))),
        findsOneWidget);
    expect(
        find.descendant(
            of: group,
            matching: find.byKey(const ValueKey('composer-dictation'))),
        findsOneWidget);
    final idle = border();
    await tester.tap(find.byTooltip('Dictate'));
    await tester.pump();
    expect(border(), isNot(idle));
    expect(border(), Theme.of(tester.element(group)).colorScheme.error);
  });

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

  testWidgets('right rail mic starts on the first tap and keeps Send',
      (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final dictation = _FakeDictation();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: MarkdownComposer(
        controller: controller,
        chatStyle: true,
        twoRowLayout: true,
        leadingControls: const SizedBox(width: 32, height: 32),
        dictation: dictation,
        sendTooltip: 'Send message',
        onSend: () {},
      )),
    ));

    await tester.tap(find.byKey(const ValueKey('composer-dictation')));
    await tester.pump();
    expect(dictation.startedLanguage, 'en-US');
    expect(find.byIcon(Icons.stop_circle_outlined), findsOneWidget);
    expect(find.byKey(const ValueKey('composer-send-Send message')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('composer-dictation-language')),
        findsNothing);
    dictation.onTranscript!('hello');
    expect(controller.text, 'hello');

    await tester.tap(find.byKey(const ValueKey('composer-dictation')));
    await tester.pump();
    expect(dictation.stopped, 1);
    expect(find.byIcon(Icons.mic_none), findsOneWidget);
  });

  testWidgets('right rail language is chosen from a long press on the mic',
      (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final dictation = _FakeDictation();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: MarkdownComposer(
        controller: controller,
        chatStyle: true,
        twoRowLayout: true,
        leadingControls: const SizedBox(width: 32, height: 32),
        dictation: dictation,
        sendTooltip: 'Send message',
        onSend: () {},
      )),
    ));

    await tester.longPress(find.byKey(const ValueKey('composer-dictation')));
    await tester.pumpAndSettle();
    expect(dictation.startedLanguage, isNull);
    await tester.tap(find.byKey(const ValueKey('dictation-language-uk-UA')));
    await tester.pumpAndSettle();
    expect(dictation.preferredLanguage, 'uk-UA');
    expect(dictation.startedLanguage, isNull);

    await tester.tap(find.byKey(const ValueKey('composer-dictation')));
    await tester.pump();
    expect(dictation.startedLanguage, 'uk-UA');
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

  testWidgets('selected language is used and remembered', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final dictation = _FakeDictation();
    await pump(tester, controller, dictation);
    expect(find.text('EN'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('composer-dictation-language')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('dictation-language-uk-UA')));
    await tester.pumpAndSettle();
    expect(dictation.preferredLanguage, 'uk-UA');
    expect(find.text('UK'), findsOneWidget);

    await tester.tap(find.byTooltip('Dictate'));
    await tester.pump();
    expect(dictation.startedLanguage, 'uk-UA');

    // A new composer on this device starts from the saved choice.
    await tester.pumpWidget(const SizedBox());
    await pump(tester, controller, dictation);
    expect(find.text('UK'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('composer-dictation-language')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('dictation-language-browser')));
    await tester.pumpAndSettle();
    expect(dictation.preferredLanguage, isNull);
    expect(find.text('EN'), findsOneWidget);
  });

  testWidgets('two-row layout puts the mic right before send', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await pump(tester, controller, _FakeDictation(), twoRowLayout: true);
    final mic = tester.getRect(find.byTooltip('Dictate'));
    final send =
        tester.getRect(find.widgetWithIcon(IconButton, Icons.send_rounded));
    final markdown = tester.getRect(find.byTooltip('Show Markdown controls'));
    expect(mic.left, greaterThan(markdown.right));
    expect(send.left - mic.right, lessThan(8));
  });
}
