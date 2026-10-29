@TestOn('browser')
library;

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
}
