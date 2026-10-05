import 'package:conclave_app/src/features/common/markdown_composer.dart';
import 'package:conclave_app/src/features/common/conclave_markdown_body.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
  testWidgets('Enter authors a newline while Cmd/Ctrl Enter submits source',
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
    expect(sends, 0);
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
    expect(sends, 2);
    expect(controller.text, '**raw**\n');
    await tester.tap(find.byTooltip('Send message'));
    expect(sends, 3);
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
