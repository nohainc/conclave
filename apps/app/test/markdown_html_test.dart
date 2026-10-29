import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/features/common/html_markdown/markdown_html.dart';

void main() {
  test('renders GFM structure', () {
    final html = renderMarkdownHtml(
        '# Title\n\n**bold** ~~gone~~\n\n| a | b |\n|:-|-:|\n| 1 | 2 |\n\n- [x] done');
    expect(html, contains('<h1>Title</h1>'));
    expect(html, contains('<strong>bold</strong>'));
    expect(html, contains('<del>gone</del>'));
    expect(html, contains('<th style="text-align:left">a</th>'));
    expect(html, contains('type="checkbox" disabled checked'));
  });

  test('escapes raw inline and block HTML', () {
    final html = renderMarkdownHtml(
        'hi <img src=x onerror=alert(1)>\n\n<script>alert(1)</script>\n\n<div onclick="x">d</div>');
    expect(html, isNot(contains('<img')));
    expect(html, isNot(contains('<script')));
    expect(html, isNot(contains('<div')));
    expect(html, contains('&lt;script&gt;'));
  });

  test('only validated web links keep an href', () {
    final html = renderMarkdownHtml(
        '[ok](https://example.com/a?b=1) [bad](javascript:alert(1)) '
        '[cred](https://u@evil.com)');
    expect(html, contains('href="https://example.com/a?b=1"'));
    expect(html, contains('rel="noopener noreferrer nofollow"'));
    expect(html, isNot(contains('javascript:')));
    expect(html, isNot(contains('evil.com"')));
  });

  test('images degrade to alt text', () {
    final html =
        renderMarkdownHtml('![chart "x"](https://tracker.example/p.png)');
    expect(html, isNot(contains('tracker.example')));
    expect(html, contains('chart &quot;x&quot;'));
  });

  test('code blocks are escaped with a sanitized language and copy button', () {
    final html =
        renderMarkdownHtml('```ts" onload="x\nconst a = 1 < 2 && "<b>";\n```');
    expect(html, contains('data-syntila-copy'));
    expect(html, isNot(contains('onload="')));
    expect(html, contains('&lt;'));
  });

  test('highlights known languages with fixed token classes', () {
    final html = renderMarkdownHtml('```dart\nfinal s = "<x>"; // hi\n```');
    expect(html, contains('<span class="smd-kw">final</span>'));
    expect(html, contains('&quot;&lt;x&gt;&quot;'));
    expect(html, contains('<span class="smd-com">'));
    final classes =
        RegExp(r'class="([^"]*)"').allMatches(html).map((m) => m.group(1)!);
    expect(
        classes
            .every((c) => c.startsWith('smd-') || c.startsWith('syntila-md')),
        isTrue);
  });

  test('unknown languages stay plain escaped text', () {
    final html = renderMarkdownHtml('```cobol\nA < B\n```');
    expect(html, isNot(contains('smd-')));
    expect(html, contains('A &lt; B'));
  });

  test('blocks join to the full document, one element each', () {
    const src = '# A\n\npara\n\n- x\n- y\n\n```js\nlet a\n```';
    final blocks = renderMarkdownBlocks(src);
    expect(blocks.join(), renderMarkdownHtml(src));
    expect(blocks, hasLength(4));
    for (final b in blocks) {
      expect(b, startsWith('<'));
    }
  });

  test('streaming appends only touch the tail block', () {
    final before = renderMarkdownBlocks('# A\n\nfirst\n\nsec');
    final after = renderMarkdownBlocks('# A\n\nfirst\n\nsecond line');
    final d = diffBlocks(before, after);
    expect((d.start, d.previousEnd, d.nextEnd), (2, 3, 3));
  });

  test('unclosed code fence during streaming stays one code block', () {
    final blocks = renderMarkdownBlocks('text\n\n```dart\nfinal a');
    expect(blocks, hasLength(2));
    expect(blocks.last, contains('syntila-md-code'));
  });

  test('diff of identical and inserted-middle lists', () {
    expect(diffBlocks(['a', 'b'], ['a', 'b']),
        (start: 2, previousEnd: 2, nextEnd: 2));
    expect(diffBlocks(['a', 'c'], ['a', 'b', 'c']),
        (start: 1, previousEnd: 1, nextEnd: 2));
  });
}
