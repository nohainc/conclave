import 'package:conclave_app/src/brand.dart';
import 'package:conclave_app/src/features/common/conclave_code_block.dart';
import 'package:conclave_app/src/features/common/conclave_markdown_body.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectedContent;
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
  testWidgets(
      'note previews preserve blank-line spacing without changing messages',
      (tester) async {
    Future<double> height(String data, bool preserve) async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
        body: ConclaveMarkdownBody(data: data, preserveBlankLines: preserve),
      )));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      return tester.getSize(find.byType(ConclaveMarkdownBody)).height;
    }

    final normal = await height('Alpha\n\nBeta', false);
    expect(await height('Alpha\n\n\n\nBeta', false), normal);
    final oneBlank = await height('Alpha\n\nBeta', true);
    final threeBlanks = await height('Alpha\n\n\n\nBeta', true);
    expect(threeBlanks, greaterThan(oneBlank));
    expect(await height('\n\nAlpha\n \n\nBeta\n\n', true),
        greaterThan(threeBlanks));
  });

  testWidgets(
      'visible blank lines retain headings, lists and literal code whitespace',
      (tester) async {
    const note = '# Heading\n\n- Item\n\n```text\none\n\nthree\n```\n\nTail';
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
      body: ConclaveMarkdownBody(data: note, preserveBlankLines: true),
    )));
    await tester.pumpAndSettle();
    expect(find.text('Heading', findRichText: true), findsOneWidget);
    expect(find.text('Item', findRichText: true), findsOneWidget);
    expect(find.text('Tail', findRichText: true), findsOneWidget);
    expect(
        tester.widget<ConclaveCodeBlock>(find.byType(ConclaveCodeBlock)).code,
        contains('one\n\nthree'));
    expect(tester.takeException(), isNull);
  });

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

  testWidgets('each message keeps Select All inside its message boundary',
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
        body: Column(
          children: [
            ConclaveMarkdownBody(data: 'First message.'),
            ConclaveMarkdownBody(data: 'Second message.'),
          ],
        ),
      ),
    ));

    await tester.pumpAndSettle();
    final regions = find.byType(SelectableRegion);
    expect(regions, findsNWidgets(2));
    final first = tester.state<SelectableRegionState>(regions.at(0));
    first.selectAll();
    await tester.pump();
    first.contextMenuButtonItems
        .firstWhere((item) => item.type == ContextMenuButtonType.copy)
        .onPressed!();
    await tester.pump();

    expect(copied, 'First message.');
  });

  testWidgets('mouse drag selection spans rich Markdown and code',
      (tester) async {
    SelectedContent? selected;
    const data =
        'First paragraph.\n\n```dart\nfinal value = 1;\n```\n\nLast paragraph.';
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ConclaveMarkdownBody(
          data: data,
          onSelectionChanged: (value) => selected = value,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(
      tester.getTopLeft(find.text('First paragraph.')),
      kind: PointerDeviceKind.mouse,
    );
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.moveTo(tester.getBottomRight(find.text('Last paragraph.')));
    await gesture.up();
    await tester.pump();

    expect(selected?.plainText, contains('First paragraph.'));
    expect(selected?.plainText, contains('final value = 1;'));
    expect(selected?.plainText, contains('Last paragraph.'));
  });

  testWidgets('dragging text after a code block selects that text',
      (tester) async {
    SelectedContent? selected;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: ConclaveMarkdownBody(
        data: 'first\n\n```dart\nfinal x = 1;\n```\n\nafter code',
        onSelectionChanged: (value) => selected = value,
      )),
    ));
    await tester.pumpAndSettle();
    final rect = tester.getRect(find.textContaining('after code'));
    final gesture = await tester.startGesture(
        Offset(rect.left + 1, rect.top + 8),
        kind: PointerDeviceKind.mouse);
    await gesture.moveTo(Offset(rect.right - 1, rect.top + 8));
    await gesture.up();
    await tester.pump();
    expect(selected?.plainText, 'after code');
  });

  for (final prefix in [
    '```dart\nfinal x = 1;\n```',
    '| Name | State |\n| --- | --- |\n| Worker | Ready |',
    '> ```dart\n> final x = 1;\n> ```',
    '> | Name | State |\n> | --- | --- |\n> | Worker | Ready |',
    '- Item\n\n  ```dart\n  final x = 1;\n  ```',
  ]) {
    testWidgets('drag selects text after an inset block: $prefix',
        (tester) async {
      SelectedContent? selected;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.fromLTRB(80, 100, 40, 0),
            child: SingleChildScrollView(
              child: ConclaveMarkdownBody(
                data: '$prefix\n\nafter block',
                onSelectionChanged: (value) => selected = value,
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      final rect = tester.getRect(find.text('after block'));
      final gesture = await tester.startGesture(
        Offset(rect.left + 1, rect.center.dy),
        kind: PointerDeviceKind.mouse,
      );
      addTearDown(gesture.removePointer);
      await gesture.moveTo(Offset(rect.right - 1, rect.center.dy));
      await gesture.up();
      await tester.pump();
      expect(selected?.plainText, 'after block');

      final reverse = await tester.startGesture(
        Offset(rect.right - 1, rect.center.dy),
        kind: PointerDeviceKind.mouse,
      );
      addTearDown(reverse.removePointer);
      await reverse.moveTo(Offset(rect.left + 1, rect.center.dy));
      await reverse.up();
      await tester.pump();
      expect(selected?.plainText, 'after block');
    });
  }

  testWidgets('selection crosses quoted code in both directions',
      (tester) async {
    SelectedContent? selected;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(40),
          child: ConclaveMarkdownBody(
            data: 'Before.\n\n> ```dart\n> final x = 1;\n> ```\n\nAfter.',
            onSelectionChanged: (value) => selected = value,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final start = tester.getTopLeft(find.text('Before.'));
    final end = tester.getBottomRight(find.text('After.'));
    for (final reverse in [false, true]) {
      final gesture = await tester.startGesture(reverse ? end : start,
          kind: PointerDeviceKind.mouse);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(reverse ? start : end);
      await gesture.up();
      await tester.pump();
      expect(selected?.plainText, contains('Before.'));
      expect(selected?.plainText, contains('final x = 1;'));
      expect(selected?.plainText, contains('After.'));
    }
  });

  testWidgets('selection is refreshed when a live message is replaced',
      (tester) async {
    String data = 'Old response';
    final selections = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: ConclaveMarkdownBody(
              data: data,
              onSelectionChanged: (value) {
                if (value != null) selections.add(value.plainText);
              },
            ),
            floatingActionButton: FloatingActionButton(
              onPressed: () => setState(() => data = 'New response'),
              child: const Icon(Icons.refresh),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final first =
        tester.state<SelectableRegionState>(find.byType(SelectableRegion));
    first.selectAll();
    await tester.pump();
    expect(selections.last, 'Old response');

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();
    final second =
        tester.state<SelectableRegionState>(find.byType(SelectableRegion));
    second.selectAll();
    await tester.pump();
    expect(selections.last, 'New response');
  });

  testWidgets('long responses retain rich rendering and selection',
      (tester) async {
    final paragraphs = List<String>.generate(
        220, (index) => 'Paragraph $index with **bold** and `inline code`.');
    final data = [
      '# Long response',
      '| Name | State |\n| --- | --- |\n| Worker | Ready |',
      '```json\n{"status":"ready","items":[1,2,3]}\n```',
      ...paragraphs,
    ].join('\n\n');

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ConclaveMarkdownBody(data: data),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final region =
        tester.state<SelectableRegionState>(find.byType(SelectableRegion));
    region.selectAll();
    await tester.pump();
    expect(find.byType(Table), findsOneWidget);
    expect(find.byType(ConclaveCodeBlock), findsOneWidget);
    expect(
        find.byWidgetPredicate((widget) =>
            widget is SingleChildScrollView &&
            widget.scrollDirection == Axis.horizontal),
        findsNWidgets(2));
    expect(tester.takeException(), isNull);
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

    destination = null;
    await tester.tap(find.text('Docs'));
    await tester.pump();
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
