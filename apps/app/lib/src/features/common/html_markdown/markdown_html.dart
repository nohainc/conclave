import 'package:highlight/highlight_core.dart' as hl;
import 'package:markdown/markdown.dart' as md;

import '../syntila_code_block.dart' show SyntilaSyntaxHighlighter;
import '../syntila_markdown_body.dart' show validatedMarkdownLink;

/// Renders GFM source to an HTML string for the browser-DOM message renderer.
///
/// The output is built from the Markdown AST through an allowlist, never by
/// passing parser HTML through: raw HTML in the source (inline or block) is
/// emitted as escaped text, only allowlisted tags/attributes are produced,
/// links must pass [validatedMarkdownLink], and images degrade to their alt
/// text so authored content cannot load remote resources.
String renderMarkdownHtml(String source) => renderMarkdownBlocks(source).join();

/// Same output as [renderMarkdownHtml], split into top-level blocks so the DOM
/// renderer can replace only blocks that changed while a response streams.
List<String> renderMarkdownBlocks(String source) {
  final document = md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
    // Keep text raw; this renderer owns all escaping.
    encodeHtml: false,
  );
  final nodes =
      document.parseLines(source.replaceAll('\r\n', '\n').split('\n'));
  return [for (final node in nodes) _renderNode(node)]
      .where((block) => block.isNotEmpty)
      .toList();
}

/// Index range `[start, end)` of [previous] to replace with
/// `next.sublist(start, next.length - (previous.length - end))`, keeping the
/// longest unchanged prefix and suffix.
({int start, int previousEnd, int nextEnd}) diffBlocks(
    List<String> previous, List<String> next) {
  var start = 0;
  while (start < previous.length &&
      start < next.length &&
      previous[start] == next[start]) {
    start++;
  }
  var previousEnd = previous.length;
  var nextEnd = next.length;
  while (previousEnd > start &&
      nextEnd > start &&
      previous[previousEnd - 1] == next[nextEnd - 1]) {
    previousEnd--;
    nextEnd--;
  }
  return (start: start, previousEnd: previousEnd, nextEnd: nextEnd);
}

String _renderNode(md.Node node) {
  final out = StringBuffer();
  _write(out, node);
  return out.toString();
}

const _allowedTags = <String>{
  'p', 'br', 'hr', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', //
  'em', 'strong', 'del', 'code', 'pre', 'blockquote',
  'ul', 'ol', 'li', 'input',
  'table', 'thead', 'tbody', 'tr', 'th', 'td',
  'a', 'sup', 'section',
};

const _voidTags = <String>{'br', 'hr', 'input'};

void _write(StringBuffer out, md.Node node) {
  if (node is md.Text) {
    out.write(escapeHtml(node.textContent));
    return;
  }
  if (node is! md.Element) return;
  final tag = node.tag;
  if (tag == 'img') {
    final alt = node.attributes['alt'];
    out.write('<span class="syntila-md-image">');
    out.write(escapeHtml(alt == null || alt.isEmpty ? 'Image' : alt));
    out.write('</span>');
    return;
  }
  if (tag == 'pre') {
    _writeCodeBlock(out, node);
    return;
  }
  if (!_allowedTags.contains(tag)) {
    // Unknown structure keeps its text but loses its markup.
    node.children?.forEach((child) => _write(out, child));
    return;
  }
  out.write('<$tag');
  _writeAttributes(out, node);
  out.write('>');
  if (_voidTags.contains(tag)) return;
  node.children?.forEach((child) => _write(out, child));
  out.write('</$tag>');
}

void _writeAttributes(StringBuffer out, md.Element node) {
  final attrs = node.attributes;
  switch (node.tag) {
    case 'a':
      final uri = validatedMarkdownLink(attrs['href']);
      if (uri != null) {
        out.write(' href="${escapeHtml(uri.toString())}"');
        out.write(' rel="noopener noreferrer nofollow" target="_blank"');
      }
    case 'input':
      // GFM task-list checkboxes only.
      out.write(' type="checkbox" disabled');
      if (attrs.containsKey('checked')) out.write(' checked');
    case 'th' || 'td':
      final align = attrs['align'];
      if (align == 'left' || align == 'center' || align == 'right') {
        out.write(' style="text-align:$align"');
      }
    case 'ol':
      final start = int.tryParse(attrs['start'] ?? '');
      if (start != null && start != 1) out.write(' start="$start"');
  }
}

void _writeCodeBlock(StringBuffer out, md.Element pre) {
  final code = pre.children?.whereType<md.Element>().firstOrNull;
  final language = (code?.attributes['class'] ?? '')
      .replaceFirst('language-', '')
      .replaceAll(RegExp(r'[^A-Za-z0-9_+#.-]'), '');
  final text = (code ?? pre).textContent.replaceFirst(RegExp(r'\n$'), '');
  out.write('<div class="syntila-md-code">');
  out.write('<div class="syntila-md-code-bar"><span>');
  out.write(escapeHtml(language.isEmpty ? 'text' : language));
  out.write('</span><button type="button" data-syntila-copy>Copy</button>');
  out.write('</div><pre><code');
  if (language.isNotEmpty) out.write(' data-language="$language"');
  out.write('>');
  final tokens = SyntilaSyntaxHighlighter.parseTokens(text, language);
  if (tokens == null) {
    out.write(escapeHtml(text));
  } else {
    for (final token in tokens) {
      _writeToken(out, token);
    }
  }
  out.write('</code></pre></div>');
}

/// Token classes are mapped to a fixed set, never copied from the grammar.
void _writeToken(StringBuffer out, hl.Node node) {
  final kind = switch (node.className) {
    'keyword' || 'selector-tag' || 'tag' => 'kw',
    'string' || 'attr' || 'attribute' => 'str',
    'number' || 'literal' => 'num',
    'comment' => 'com',
    'title' || 'built_in' => 'ttl',
    _ => null,
  };
  if (kind != null) out.write('<span class="smd-$kind">');
  if (node.value != null) out.write(escapeHtml(node.value!));
  node.children?.forEach((child) => _writeToken(out, child));
  if (kind != null) out.write('</span>');
}

String escapeHtml(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
