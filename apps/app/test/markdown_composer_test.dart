import 'package:conclave_app/src/features/common/markdown_composer.dart';
import 'package:conclave_app/src/features/common/conclave_markdown_body.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final brightness in Brightness.values) {
    for (final toolbarSend in [false, true]) {
      testWidgets(
          'composer control colors $brightness toolbarSend=$toolbarSend',
          (tester) async {
        final controller = TextEditingController(text: 'Draft');
        addTearDown(controller.dispose);
        final theme = ThemeData(brightness: brightness);
        await tester.pumpWidget(MaterialApp(
          theme: theme,
          home: Scaffold(
              body: MarkdownComposer(
            controller: controller,
            chatStyle: true,
            sendInToolbar: toolbarSend,
            additionalControlsBuilder:
                toolbarSend ? (_) => const Text("Options") : null,
            showMarkdownControlsInSuffix: !toolbarSend,
            onSend: () {},
          )),
        ));
        void expectControls(String toggle) {
          final icon = tester.widget<Icon>(find.descendant(
              of: find.byTooltip(toggle), matching: find.byType(Icon)));
          expect(icon.color, theme.colorScheme.onSurface);
          final send = tester.widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.send_rounded));
          expect(send.color, theme.colorScheme.onSurface);
          expect(find.byType(Divider), findsNothing);
        }

        expectControls('Show Markdown controls');
        await tester.tap(find.byTooltip('Show Markdown controls'));
        await tester.pump();
        expectControls('Hide Markdown controls');
        expect(
            tester
                .widget<IconButton>(
                    find.widgetWithIcon(IconButton, Icons.format_bold))
                .color,
            theme.colorScheme.onSurface);
        final preview = tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Preview'));
        expect(preview.style?.foregroundColor?.resolve({}),
            theme.colorScheme.onSurface);
        await tester.tap(find.text('Preview'));
        await tester.pump();
        final write =
            tester.widget<TextButton>(find.widgetWithText(TextButton, 'Write'));
        expect(write.style?.foregroundColor?.resolve({}),
            theme.colorScheme.onSurface);
        expect(find.byType(Divider), findsNothing);
      });
    }
  }

  testWidgets(
      'toolbar Send stays visible on narrow screens while typing remains enabled',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MarkdownComposer(
      controller: controller,
      chatStyle: true,
      sendInToolbar: true,
      sendEnabled: false,
      onSend: () {},
      additionalControlsBuilder: (_) => const SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child:
              Row(children: [Text('Worker · Model · Effort · extra options')])),
    ))));
    expect(find.byTooltip('Send message'), findsOneWidget);
    expect(
        find.descendant(
            of: find.byType(TextField),
            matching: find.byTooltip('Send message')),
        findsNothing);
    expect(tester.getRect(find.byTooltip('Send message')).right,
        lessThanOrEqualTo(360));
    expect(
        tester
            .widget<IconButton>(find.ancestor(
                of: find.byIcon(Icons.send_rounded),
                matching: find.byType(IconButton)))
            .onPressed,
        isNull);
    await tester.enterText(find.byType(TextField), 'Draft next request');
    expect(controller.text, 'Draft next request');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Chat restores compact send controls and hides formatting by default',
      (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MarkdownComposer(
                controller: controller,
                chatStyle: true,
                onSend: controller.clear))));
    expect(find.byTooltip('Bold'), findsNothing);
    expect(find.text('Preview'), findsNothing);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.decoration?.hintText, isNull);
    expect(field.minLines, 1);
    expect(
        find.descendant(
            of: find.byType(TextField),
            matching: find.byTooltip('Send message')),
        findsOneWidget);
    await tester.tap(find.byTooltip('Show Markdown controls'));
    await tester.pump();
    expect(find.byTooltip('Bold'), findsOneWidget);
    expect(tester.getTopLeft(find.byTooltip('Bold')).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(find.byType(TextField)).dy));
    expect(find.text('Preview'), findsOneWidget);
    expect(find.text('Write'), findsNothing);
    expect(tester.getTopLeft(find.text('Preview')).dx,
        greaterThan(tester.getTopLeft(find.byTooltip('Task list')).dx));
    controller.text = 'Ready to send';
    await tester.tap(find.text('Preview'));
    await tester.pump();
    expect(find.text('Preview'), findsNothing);
    expect(find.text('Write'), findsOneWidget);
    expect(tester.getCenter(find.text('Write')).dy,
        closeTo(tester.getCenter(find.byTooltip('Task list')).dy, 1));
    expect(find.byIcon(Icons.send_rounded), findsOneWidget);
    expect(tester.getCenter(find.byTooltip('Send message')).dy,
        closeTo(tester.getCenter(find.text('Write')).dy, 1));
    expect(tester.getTopLeft(find.byTooltip('Send message')).dx,
        greaterThan(tester.getTopLeft(find.text('Write')).dx));
    controller.text = 'Ready to send';
    await tester.pump();
    await tester.tap(find.byTooltip('Send message'));
    await tester.pump();
    expect(controller.text, isEmpty);
    expect(find.text('Preview'), findsOneWidget);
    expect(find.text('Write'), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
    await tester.tap(find.byTooltip('Hide Markdown controls'));
    await tester.pump();
    expect(find.byTooltip('Bold'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('two-pane toolbar keeps Send at the right in Write and Preview',
      (tester) async {
    final controller = TextEditingController(text: '**Draft**');
    addTearDown(controller.dispose);
    var sends = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
                width: 460,
                child: MarkdownComposer(
                  controller: controller,
                  chatStyle: true,
                  onSend: () => sends++,
                  showMarkdownControls: false,
                  showMarkdownControlsInSuffix: false,
                  showSendInSuffix: false,
                  sendInFormattingToolbar: true,
                )))));
    expect(find.byTooltip('Show Markdown controls'), findsNothing);
    expect(find.byTooltip('Hide Markdown controls'), findsNothing);
    expect(find.byTooltip('Bold'), findsOneWidget);
    for (final mode in ['Preview', 'Write']) {
      expect(find.byTooltip('Send message'), findsOneWidget);
      expect(tester.getCenter(find.byTooltip('Send message')).dy,
          closeTo(tester.getCenter(find.text(mode)).dy, 1));
      expect(
          tester
              .getRect(find.widgetWithIcon(IconButton, Icons.send_rounded))
              .right,
          closeTo(454, 1));
      await tester.tap(find.text(mode));
      await tester.pump();
    }
    await tester.tap(find.byTooltip('Send message'));
    expect(sends, 1);
    expect(controller.text, '**Draft**');
    expect(tester.takeException(), isNull);
  });

  test('empty selections, multiline prefixes and quote toggle', () {
    for (final format in MarkdownFormat.values) {
      final controller = TextEditingController();
      formatMarkdown(controller, format);
      expect(controller.text, isNotEmpty, reason: format.name);
      expect(controller.selection.isValid, isTrue);
      controller.dispose();
    }
    for (final (format, prefix) in [
      (MarkdownFormat.heading, '## '),
      (MarkdownFormat.bulletList, '- '),
      (MarkdownFormat.taskList, '- [ ] '),
      (MarkdownFormat.quote, '> '),
    ]) {
      final controller = TextEditingController(text: 'one\ntwo')
        ..selection = const TextSelection(baseOffset: 0, extentOffset: 7);
      formatMarkdown(controller, format);
      expect(controller.text, '${prefix}one\n${prefix}two');
      if (format == MarkdownFormat.quote) {
        formatMarkdown(controller, format);
        expect(controller.text, 'one\ntwo');
      }
      controller.dispose();
    }
    final controller = TextEditingController(text: 'one\ntwo')
      ..selection = const TextSelection(baseOffset: 0, extentOffset: 7);
    formatMarkdown(controller, MarkdownFormat.codeBlock);
    expect(controller.text, '```\none\ntwo\n```');
    controller.dispose();
  });
  testWidgets(
      'Enter sends, Shift Enter authors a newline, and Cmd/Ctrl Enter sends',
      (tester) async {
    final controller = TextEditingController(text: '**raw**');
    addTearDown(controller.dispose);
    var sends = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MarkdownComposer(
      controller: controller,
      onSend: () => sends++,
    ))));
    await tester.tap(find.byType(TextField));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(sends, 1);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(sends, 1);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.textInputAction, TextInputAction.newline);
    // The platform text-input service delivers the newline to the controller.
    tester.testTextInput.enterText('**raw**\n');
    for (final modifier in [
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.metaLeft
    ]) {
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(modifier);
    }
    expect(sends, 3);
    expect(controller.text, '**raw**\n');
    await tester.tap(find.byTooltip('Send message'));
    expect(sends, 4);
  });

  testWidgets('Enter submits edit and Shift Enter keeps a newline',
      (tester) async {
    final controller = TextEditingController(text: 'draft');
    addTearDown(controller.dispose);
    var submits = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MarkdownComposer(
      controller: controller,
      onSubmit: () => submits++,
    ))));

    await tester.tap(find.byType(TextField));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(submits, 1);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(submits, 1);
  });

  test('inline and fenced edits preserve selected content', () {
    for (final (format, expected) in [
      (MarkdownFormat.bold, '**hello**'),
      (MarkdownFormat.italic, '*hello*'),
      (MarkdownFormat.inlineCode, '`hello`'),
      (MarkdownFormat.codeBlock, '```\nhello\n```'),
      (MarkdownFormat.link, '[hello](url)'),
    ]) {
      final controller = TextEditingController(text: 'hello')
        ..selection = const TextSelection(baseOffset: 0, extentOffset: 5);
      formatMarkdown(controller, format);
      expect(controller.text, expected);
      expect(controller.selection.textInside(controller.text),
          format == MarkdownFormat.link ? 'url' : 'hello');
      controller.dispose();
    }
  });

  test('line formatting affects selected lines without touching neighbors', () {
    final controller = TextEditingController(text: 'before\none\ntwo\nafter')
      ..selection = const TextSelection(baseOffset: 8, extentOffset: 15);
    formatMarkdown(controller, MarkdownFormat.numberedList);
    expect(controller.text, 'before\n1. one\n2. two\nafter');
    controller.dispose();
  });

  testWidgets('composer preview keeps source and keyboard formatting works',
      (tester) async {
    final controller = TextEditingController(text: 'hello');
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: MarkdownComposer(controller: controller))));
    await tester.tap(find.byType(TextField));
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(controller.text, '**hello**');
    await tester.tap(find.text('Preview'));
    await tester.pump();
    expect(
        tester
            .widget<ConclaveMarkdownBody>(find.byType(ConclaveMarkdownBody))
            .data,
        '**hello**');
    await tester.tap(find.text('Write'));
    await tester.pump();
    expect(controller.text, '**hello**');
  });
}
