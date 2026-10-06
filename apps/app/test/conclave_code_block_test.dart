import 'package:conclave_app/src/features/common/conclave_code_block.dart';
import 'package:conclave_app/src/features/common/conclave_markdown_body.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('highlighting preserves source for supported and unknown languages', () {
    for (final language in [
      'dart',
      'ts',
      'js',
      'json',
      'yaml',
      'sql',
      'bash',
      'python',
      'html',
      'css',
      'unknown',
      ''
    ]) {
      const code = '  const value = "hello";\n\n';
      final span = ConclaveSyntaxHighlighter(ThemeData(), language: language)
          .format(code);
      expect(span.toPlainText(), code, reason: language);
      if (language == 'unknown' || language.isEmpty) {
        expect(span.children, isNull);
      }
    }
    final span = ConclaveSyntaxHighlighter(ThemeData(), language: 'dart')
        .format('final ready = true;');
    expect(span.children, isNotEmpty);
  });

  testWidgets('fence metadata, scrolling, selection and exact code copy',
      (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    const code = '  final value = "<b>raw</b>";\n';
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: SizedBox(
                width: 320,
                child: ConclaveMarkdownBody(
                    data: '```dart\n$code```\n\n`inline`')))));
    final block =
        tester.widget<ConclaveCodeBlock>(find.byType(ConclaveCodeBlock));
    expect(block.language, 'dart');
    expect(block.code, code);
    expect(
        find.byWidgetPredicate((widget) =>
            widget is SingleChildScrollView &&
            widget.scrollDirection == Axis.horizontal),
        findsOneWidget);
    expect(find.byType(SelectionArea), findsOneWidget);
    await tester.tap(find.byTooltip('Copy code'));
    await tester.pump();
    expect(copied, code);
    expect(tester.takeException(), isNull);
  });
}
