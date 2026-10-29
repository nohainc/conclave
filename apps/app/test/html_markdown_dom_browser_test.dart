@TestOn('browser')
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/features/common/html_markdown/html_markdown_view_web.dart';
import 'package:syntila_app/src/features/common/html_markdown/markdown_html.dart';
import 'package:web/web.dart' as web;

void main() {
  test('streaming patch keeps unchanged block nodes', () {
    final root = web.document.createElement('div');
    var blocks = <String>[];
    void render(String source) {
      final next = renderMarkdownBlocks(source);
      patchMarkdownBlocks(root, blocks, next);
      blocks = next;
    }

    render('# Title\n\nfirst');
    final heading = root.children.item(0);
    render('# Title\n\nfirst para\n\n```dart\nfinal a');
    expect(identical(root.children.item(0), heading), isTrue);
    expect(root.children.length, 3);
    expect(root.querySelector('.smd-kw')?.textContent, 'final');

    render('# Title\n\nfirst para');
    expect(identical(root.children.item(0), heading), isTrue);
    expect(root.children.length, 2);
    expect(
        root.innerHTML.toString(), renderMarkdownHtml('# Title\n\nfirst para'));
  });

  test('raw HTML never becomes live DOM', () {
    final root = web.document.createElement('div');
    patchMarkdownBlocks(
        root,
        const [],
        renderMarkdownBlocks(
            '<img src=x onerror=alert(1)>\n\n<script>x</script>'));
    expect(root.querySelector('img'), isNull);
    expect(root.querySelector('script'), isNull);
  });

  test('selection guard scopes pointerdown to the active message root', () {
    final first = web.document.createElement('div') as web.HTMLDivElement;
    final second = web.document.createElement('div') as web.HTMLDivElement;
    patchMarkdownBlocks(first, const [], renderMarkdownBlocks('First message'));
    patchMarkdownBlocks(
        second, const [], renderMarkdownBlocks('Second message'));
    web.document.body!.append(first);
    web.document.body!.append(second);
    registerMarkdownRootForTesting(first);
    registerMarkdownRootForTesting(second);
    addTearDown(() {
      unregisterMarkdownRootForTesting(first);
      unregisterMarkdownRootForTesting(second);
      first.remove();
      second.remove();
    });

    first.dispatchEvent(web.PointerEvent(
      'pointerdown',
      web.PointerEventInit(bubbles: true, button: 0),
    ));
    expect(first.style.getPropertyValue('user-select'), 'text');
    expect(second.style.getPropertyValue('user-select'), 'none');

    web.window.dispatchEvent(
        web.PointerEvent('pointerup', web.PointerEventInit(bubbles: true)));
    expect(first.style.getPropertyValue('user-select'), 'text');
    expect(second.style.getPropertyValue('user-select'), 'text');
  });

  testWidgets('wheel event over HTML markdown scrolls ancestor Scrollable',
      (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          height: 200,
          child: SingleChildScrollView(
            controller: controller,
            child: const SizedBox(height: 800),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.offset, 0);

    final root = web.document.createElement('div') as web.HTMLDivElement;
    patchMarkdownBlocks(
        root, const [], renderMarkdownBlocks('Scrollable message'));
    final p = root.firstElementChild!;
    final event = web.WheelEvent(
      'wheel',
      web.WheelEventInit(bubbles: true, cancelable: true, deltaY: 120),
    );
    p.dispatchEvent(event);
    final forwarded = forwardMarkdownWheelDelta(
      event: event,
      root: root,
      position: controller.position,
    );
    expect(forwarded, isTrue);
    expect(controller.offset, 120);
  });
}
