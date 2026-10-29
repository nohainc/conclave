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
}
