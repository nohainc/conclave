import 'dart:js_interop';

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import 'html_markdown_view.dart';
import 'markdown_html.dart';

const bool htmlMarkdownSupported = true;

Widget buildHtmlMarkdownView({
  required String data,
  required ValueChanged<String> onOpenLink,
  required HtmlMarkdownStyle style,
}) =>
    _HtmlMarkdownView(data: data, onOpenLink: onOpenLink, style: style);

class _HtmlMarkdownView extends StatefulWidget {
  const _HtmlMarkdownView({
    required this.data,
    required this.onOpenLink,
    required this.style,
  });

  final String data;
  final ValueChanged<String> onOpenLink;
  final HtmlMarkdownStyle style;

  @override
  State<_HtmlMarkdownView> createState() => _HtmlMarkdownViewState();
}

class _HtmlMarkdownViewState extends State<_HtmlMarkdownView> {
  web.HTMLDivElement? _root;
  web.ResizeObserver? _observer;
  double _height = 1;
  String? _rendered;

  @override
  void didUpdateWidget(covariant _HtmlMarkdownView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void dispose() {
    _observer?.disconnect();
    super.dispose();
  }

  void _attach(Object element) {
    final host = element as web.HTMLElement;
    _ensureStylesheet();
    host.style
      ..width = '100%'
      ..height = 'auto';
    final root = web.document.createElement('div') as web.HTMLDivElement
      ..className = 'syntila-md';
    host.append(root);
    root.addEventListener('click', _onClick.toJS);
    _root = root;
    _observer = web.ResizeObserver(
      ((JSArray<web.ResizeObserverEntry> _, web.ResizeObserver __) =>
          _measure()).toJS,
    )..observe(root);
    _sync();
  }

  void _sync() {
    final root = _root;
    if (root == null) return;
    widget.style
        .toCssVariables()
        .forEach((name, value) => root.style.setProperty(name, value));
    // Replace content only when the source changes so an unchanged message
    // keeps its DOM identity and any in-progress text selection.
    if (_rendered != widget.data) {
      _rendered = widget.data;
      root.innerHTML = renderMarkdownHtml(widget.data).toJS;
    }
  }

  void _measure() {
    final height = _root?.getBoundingClientRect().height ?? 0;
    if (mounted && (height - _height).abs() > 0.5) {
      setState(() => _height = height < 1 ? 1 : height);
    }
  }

  void _onClick(web.Event event) {
    final target = event.target;
    if (target == null || !target.isA<web.Element>()) return;
    target as web.Element;
    final copy = target.closest('[data-syntila-copy]');
    if (copy != null) {
      event.preventDefault();
      final code = copy.closest('.syntila-md-code')?.querySelector('code');
      web.window.navigator.clipboard.writeText(code?.textContent ?? '');
      copy.textContent = 'Copied';
      return;
    }
    final anchor = target.closest('a');
    if (anchor != null) {
      event.preventDefault();
      final href = anchor.getAttribute('href');
      if (href != null) widget.onOpenLink(href);
    }
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        height: _height,
        child: HtmlElementView.fromTagName(
          tagName: 'div',
          onElementCreated: _attach,
        ),
      );
}

const _styleId = 'syntila-md-style';

void _ensureStylesheet() {
  if (web.document.getElementById(_styleId) != null) return;
  final style = web.document.createElement('style')
    ..id = _styleId
    ..textContent = _css;
  web.document.head!.append(style);
}

const _css = '''
.syntila-md { color: var(--smd-text); font: var(--smd-font-size)/1.6 Inter, system-ui, sans-serif;
  overflow-wrap: anywhere; user-select: text; -webkit-user-select: text; cursor: auto; }
.syntila-md > :first-child { margin-top: 0; } .syntila-md > :last-child { margin-bottom: 0; }
.syntila-md p, .syntila-md ul, .syntila-md ol, .syntila-md blockquote, .syntila-md table,
.syntila-md .syntila-md-code { margin: 0 0 .75em; }
.syntila-md h1, .syntila-md h2, .syntila-md h3, .syntila-md h4 { margin: 1em 0 .5em; line-height: 1.3; font-weight: 600; }
.syntila-md h1 { font-size: 1.5em; } .syntila-md h2 { font-size: 1.3em; } .syntila-md h3 { font-size: 1.15em; }
.syntila-md a { color: var(--smd-link); text-decoration: underline; cursor: pointer; }
.syntila-md code { font-family: "JetBrains Mono", ui-monospace, monospace; font-size: .9em;
  background: var(--smd-code-bg); border-radius: 4px; padding: .1em .3em; }
.syntila-md blockquote { border-left: 3px solid var(--smd-border); padding-left: .9em; color: var(--smd-muted); }
.syntila-md hr { border: 0; border-top: 1px solid var(--smd-border); margin: 1em 0; }
.syntila-md table { display: block; max-width: 100%; overflow-x: auto; border-collapse: collapse; }
.syntila-md th, .syntila-md td { border: 1px solid var(--smd-border); padding: .35em .7em; }
.syntila-md th { font-weight: 600; }
.syntila-md li > input[type=checkbox] { margin-right: .4em; }
.syntila-md .syntila-md-image { color: var(--smd-muted); font-style: italic; }
.syntila-md .syntila-md-code { border: 1px solid var(--smd-border); border-radius: 8px; overflow: hidden; }
.syntila-md .syntila-md-code-bar { display: flex; justify-content: space-between; align-items: center;
  padding: .25em .75em; font-size: .8em; color: var(--smd-muted); border-bottom: 1px solid var(--smd-border); }
.syntila-md .syntila-md-code-bar button { font: inherit; color: inherit; background: none; border: 0; cursor: pointer; }
.syntila-md pre { margin: 0; padding: .75em; overflow-x: auto; background: var(--smd-code-bg); }
.syntila-md pre code { background: none; padding: 0; font-size: .85em; white-space: pre; }
.syntila-md .smd-kw { color: var(--smd-kw); } .syntila-md .smd-str { color: var(--smd-str); }
.syntila-md .smd-num { color: var(--smd-num); } .syntila-md .smd-ttl { color: var(--smd-ttl); }
.syntila-md .smd-com { color: var(--smd-muted); font-style: italic; }
''';
