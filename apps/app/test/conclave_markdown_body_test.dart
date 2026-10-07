import 'package:conclave_app/src/brand.dart';
import 'package:conclave_app/src/features/common/conclave_markdown_body.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;

const source = '''
# Heading
## Subheading
### Third
#### Fourth
##### Fifth
###### Sixth

**Bold** *italic* ***both*** ~~removed~~ `inline`
First line
Second line

```dart
final status = 'ready';
```

> Quoted context

1. Ordered
2. Next

- Parent
  - Nested
- [x] Done
- [ ] Pending

| Name | State |
| --- | --- |
| Worker | Ready |

[Docs](https://example.com/docs) https://example.com

---

<span>HTML stays literal</span>
''';

void main() {
  testWidgets('selection copies the whole response across paragraphs and code',
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
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
          body: ConclaveMarkdownBody(
        data:
            'First **paragraph**.\n\nSecond paragraph.\n\n```dart\nfinal value = 1;\n```\n\nLast paragraph.',
      )),
    ));
    await tester.pumpAndSettle();
    final region =
        tester.state<SelectableRegionState>(find.byType(SelectableRegion));
    region.selectAll();
    await tester.pump();
    region.contextMenuButtonItems
        .firstWhere((item) => item.type == ContextMenuButtonType.copy)
        .onPressed!();
    await tester.pump();
    expect(copied, contains('First paragraph.'));
    expect(copied, contains('Second paragraph.'));
    expect(copied, contains('final value = 1;'));
    expect(copied, contains('Last paragraph.'));
    expect(copied, isNot(contains('Copy code')));
    expect(copied, isNot(contains('dart')));
  });
  for (final content in [
    '<script>alert("unsafe")</script>',
    '<iframe src="https://example.com"></iframe>',
    '[bad](javascript:alert) [file](file:///tmp/private)',
    '![tracking](https://example.com/tracker)',
    '**unfinished [broken](\n```unknown\nunclosed',
  ]) {
    testWidgets('untrusted source renders without executable content: $content',
        (tester) async {
      var launches = 0;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: ConclaveMarkdownBody(
        data: content,
        openLink: (_) async {
          launches++;
          return true;
        },
      ))));
      expect(find.byType(Image), findsNothing);
      expect(launches, 0);
      expect(tester.takeException(), isNull);
    });
  }
  for (final brightness in Brightness.values) {
    testWidgets('GFM contract renders in $brightness', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: const Scaffold(
          body: SingleChildScrollView(
            child: ConclaveMarkdownBody(data: source),
          ),
        ),
      ));
      final renderer = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
      expect(renderer.extensionSet, same(md.ExtensionSet.gitHubFlavored));
      expect(renderer.selectable, isFalse);
      expect(find.byType(SelectionArea), findsOneWidget);
      expect(renderer.softLineBreak, isTrue);
      expect(renderer.data, source);
      expect(find.byType(Table), findsOneWidget);
      expect(find.byIcon(Icons.check_box), findsOneWidget);
      expect(find.byIcon(Icons.check_box_outline_blank), findsOneWidget);
      final text = tester
          .widgetList<Text>(find.byType(Text))
          .map((widget) => widget.textSpan?.toPlainText() ?? widget.data ?? '')
          .join('\n');
      expect(text, contains('Heading'));
      expect(text, contains('Nested'));
      expect(text, contains("final status = 'ready';"));
      expect(text, contains('<span>HTML stays literal</span>'));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('authored links delegate to the caller', (tester) async {
    String? destination;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ConclaveMarkdownBody(
          data: '[Docs](https://example.com/docs)',
          openLink: (uri) async {
            destination = uri.toString();
            return true;
          },
        ),
      ),
    ));
    final renderer = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
    renderer.onTapLink!('Docs', 'https://example.com/docs', '');
    expect(destination, 'https://example.com/docs');
  });

  test('link validation rejects unsafe and malformed destinations', () {
    for (final value in [
      null,
      '',
      'javascript:alert(1)',
      'file:///tmp/file',
      'conclave://run',
      'mailto:user@example.com',
      '/relative',
      '//example.com',
      'https://user:password@example.com',
      'https://@example.com',
      'https://',
      'https:///path',
      'https://example.com:bad',
      'https://example.com:65536',
      'https://example.com/%zz',
      'https://exa mple.com',
      'https://example.com\\path',
      'https://example.com\n',
    ]) {
      expect(validatedMarkdownLink(value), isNull, reason: '$value');
    }
    for (final value in [
      'https://example.com/path?q=value#section',
      'http://localhost:8787/path',
      'https://example.com/a%20b',
      'https://[::1]:443/',
    ]) {
      expect(validatedMarkdownLink(value), isNotNull, reason: value);
    }
  });

  testWidgets('unsafe links never reach the launcher', (tester) async {
    var launches = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ConclaveMarkdownBody(
          data: '[Unsafe](javascript:alert)',
          openLink: (_) async {
            launches++;
            return true;
          },
        ),
      ),
    ));
    final renderer = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
    renderer.onTapLink!('Unsafe', 'javascript:alert', '');
    await tester.pump();
    expect(launches, 0);
    expect(find.text('Only valid HTTP or HTTPS links can be opened.'),
        findsOneWidget);
  });

  testWidgets('images show alt text without image loading widgets',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: ConclaveMarkdownBody(
          data:
              '![Diagram](https://example.com/tracker.png)\n\n![](file:///tmp/image.png)',
        ),
      ),
    ));
    expect(find.text('Diagram'), findsOneWidget);
    expect(find.text('Image'), findsOneWidget);
    expect(find.byIcon(Icons.image_outlined), findsNWidgets(2));
    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test(
      'ConclaveMarkdownStyleSheet uses accessible brand tokens for light and dark modes',
      () {
    final lightSheet =
        ConclaveMarkdownStyleSheet.fromTheme(ConclaveBrand.lightTheme());
    final darkSheet =
        ConclaveMarkdownStyleSheet.fromTheme(ConclaveBrand.darkTheme());

    expect(lightSheet.a?.color, ConclaveColors.primaryForegroundLight);
    expect(darkSheet.a?.color, ConclaveColors.primaryForegroundDark);
    expect(lightSheet.codeblockDecoration, isNotNull);
    expect(darkSheet.codeblockDecoration, isNotNull);
  });
}
