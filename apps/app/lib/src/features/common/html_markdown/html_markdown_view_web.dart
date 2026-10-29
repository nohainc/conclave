import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import 'html_markdown_view.dart';
import 'markdown_html.dart';

const bool htmlMarkdownSupported = true;

final Set<web.HTMLElement> _activeMarkdownRoots = <web.HTMLElement>{};
bool _selectionGuardInstalled = false;
web.HTMLElement? _selectionOwnerRoot;

void _ensureSelectionGuard() {
  if (_selectionGuardInstalled) return;
  _selectionGuardInstalled = true;
  web.document.addEventListener(
    'pointerdown',
    ((web.PointerEvent event) {
      if (event.button != 0) return;
      final target = event.target;
      final root = target != null && target.isA<web.Element>()
          ? (target as web.Element).closest('.syntila-md') as web.HTMLElement?
          : null;
      _selectionOwnerRoot = root;
      for (final other in _activeMarkdownRoots) {
        final value = root == null || identical(other, root) ? 'text' : 'none';
        other.style
          ..setProperty('user-select', value)
          ..setProperty('-webkit-user-select', value);
      }
      if (root != null) {
        final selection = web.window.getSelection();
        final anchor = selection?.anchorNode;
        if (selection != null && anchor != null && !root.contains(anchor)) {
          selection.removeAllRanges();
        }
      }
    }).toJS,
    true.toJS,
  );
  web.document.addEventListener(
    'selectionchange',
    ((web.Event _) {
      final selection = web.window.getSelection();
      if (selection == null || selection.rangeCount == 0) return;
      final anchor = selection.anchorNode;
      final focus = selection.focusNode;
      if (anchor == null || focus == null) return;
      final owner = _selectionOwnerRoot ?? _containingRoot(anchor);
      if (owner == null) return;
      if (!owner.contains(anchor) || !owner.contains(focus)) {
        final range = selection.getRangeAt(0);
        if (!owner.contains(range.startContainer) && owner.firstChild != null) {
          range.setStartBefore(owner.firstChild!);
        }
        if (!owner.contains(range.endContainer) && owner.lastChild != null) {
          range.setEndAfter(owner.lastChild!);
        }
      }
    }).toJS,
  );
  void releaseSelectionLock(web.Event _) {
    _selectionOwnerRoot = null;
    for (final root in _activeMarkdownRoots) {
      root.style
        ..setProperty('user-select', 'text')
        ..setProperty('-webkit-user-select', 'text');
    }
  }

  web.window
      .addEventListener('pointerup', releaseSelectionLock.toJS, true.toJS);
  web.window
      .addEventListener('pointercancel', releaseSelectionLock.toJS, true.toJS);
}

web.HTMLElement? _containingRoot(web.Node node) {
  for (final root in _activeMarkdownRoots) {
    if (root.contains(node)) return root;
  }
  return null;
}

@visibleForTesting
void registerMarkdownRootForTesting(web.HTMLElement root) {
  _ensureStylesheet();
  _ensureSelectionGuard();
  root
    ..className = 'syntila-md'
    ..tabIndex = -1;
  _activeMarkdownRoots.add(root);
}

@visibleForTesting
void unregisterMarkdownRootForTesting(web.HTMLElement root) {
  _activeMarkdownRoots.remove(root);
  if (identical(_selectionOwnerRoot, root)) {
    _selectionOwnerRoot = null;
  }
}

@visibleForTesting
bool forwardMarkdownWheelDelta({
  required web.WheelEvent event,
  required web.Element root,
  required ScrollPosition position,
}) {
  if (event.ctrlKey || event.metaKey) return false;
  if (_consumesNestedScroll(event, root)) return false;
  if (!position.hasPixels || !position.hasContentDimensions) return false;
  final dy = _normalizeWheelDelta(event.deltaY, event.deltaMode,
      viewportDimension: position.viewportDimension);
  if (dy.abs() < 0.01) return false;
  event.preventDefault();
  event.stopPropagation();
  final target = (position.pixels + dy)
      .clamp(position.minScrollExtent, position.maxScrollExtent);
  if (target != position.pixels) {
    position.pointerScroll(dy);
    return true;
  }
  return false;
}

bool _consumesNestedScroll(web.WheelEvent event, web.Element root) {
  final dx = event.deltaX;
  final dy = event.deltaY;
  var current =
      event.target.isA<web.Element>() ? event.target as web.Element? : null;
  while (current != null && current != root && root.contains(current)) {
    if (dx.abs() >= dy.abs() && dx.abs() > 0.01) {
      final maxLeft = current.scrollWidth - current.clientWidth;
      if (maxLeft > 1) {
        final canLeft = dx < 0 && current.scrollLeft > 0;
        final canRight = dx > 0 && current.scrollLeft < maxLeft - 1;
        if (canLeft || canRight) return true;
      }
    }
    current = current.parentElement;
  }
  return false;
}

double _normalizeWheelDelta(
  double delta,
  int deltaMode, {
  required double viewportDimension,
}) =>
    switch (deltaMode) {
      1 => delta * 24.0, // DOM_DELTA_LINE
      2 => delta * viewportDimension, // DOM_DELTA_PAGE
      _ => delta, // DOM_DELTA_PIXEL
    };

Widget buildHtmlMarkdownView({
  required String data,
  required ValueChanged<String> onOpenLink,
  required HtmlMarkdownStyle style,
  bool fitContent = false,
}) =>
    _HtmlMarkdownView(
      data: data,
      onOpenLink: onOpenLink,
      style: style,
      fitContent: fitContent,
    );

class _HtmlMarkdownView extends StatefulWidget {
  const _HtmlMarkdownView({
    required this.data,
    required this.onOpenLink,
    required this.style,
    required this.fitContent,
  });

  final String data;
  final ValueChanged<String> onOpenLink;
  final HtmlMarkdownStyle style;
  final bool fitContent;

  @override
  State<_HtmlMarkdownView> createState() => _HtmlMarkdownViewState();
}

class _HtmlMarkdownViewState extends State<_HtmlMarkdownView> {
  web.HTMLDivElement? _root;
  web.ResizeObserver? _observer;
  Timer? _copyFeedbackTimer;
  double? _width;
  double _height = 1;
  double _lastMaxWidth = double.infinity;
  String? _rendered;
  List<String> _blocks = const [];

  @override
  void didUpdateWidget(covariant _HtmlMarkdownView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
    if (oldWidget.fitContent != widget.fitContent) {
      _measure();
    }
  }

  @override
  void dispose() {
    _copyFeedbackTimer?.cancel();
    _observer?.disconnect();
    final root = _root;
    if (root != null) {
      _activeMarkdownRoots.remove(root);
      if (identical(_selectionOwnerRoot, root)) {
        _selectionOwnerRoot = null;
      }
    }
    super.dispose();
  }

  void _attach(Object element) {
    final host = element as web.HTMLElement;
    _ensureStylesheet();
    _ensureSelectionGuard();
    host.style
      ..width = '100%'
      ..height = 'auto';
    final root = web.document.createElement('div') as web.HTMLDivElement
      ..className = 'syntila-md'
      ..tabIndex = -1;
    host.append(root);
    _activeMarkdownRoots.add(root);
    root.addEventListener('copy', _onCopy.toJS);
    root.addEventListener('click', _onClick.toJS);
    root.addEventListener('keydown', _onKeyDown.toJS);
    root.addEventListener(
        'wheel', _onWheel.toJS, web.AddEventListenerOptions(passive: false));
    _root = root;
    _observer = web.ResizeObserver(
      ((JSArray<web.ResizeObserverEntry> _, web.ResizeObserver __) =>
          _measure()).toJS,
    )..observe(root);
    _sync();
    _measure();
  }

  void _sync() {
    final root = _root;
    if (root == null) return;
    widget.style
        .toCssVariables()
        .forEach((name, value) => root.style.setProperty(name, value));
    root.style.width = widget.fitContent ? 'fit-content' : '100%';
    if (_lastMaxWidth.isFinite) {
      root.style.maxWidth = '${_lastMaxWidth}px';
    } else {
      root.style.removeProperty('max-width');
    }
    // Replace content only when the source changes so an unchanged message
    // keeps its DOM identity and any in-progress text selection.
    if (_rendered != widget.data) {
      _rendered = widget.data;
      final next = renderMarkdownBlocks(widget.data);
      patchMarkdownBlocks(root, _blocks, next);
      _blocks = next;
      _measure();
    }
  }

  void _measure() {
    final root = _root;
    if (root == null || !mounted) return;
    final rect = root.getBoundingClientRect();
    final height = math.max(1.0, rect.height);
    final double? width = widget.fitContent
        ? math.max(1.0, math.min(rect.width.ceilToDouble(), _lastMaxWidth))
        : null;
    final heightChanged = (height - _height).abs() > 0.5;
    final widthChanged = width == null
        ? _width != null
        : (_width == null || (width - _width!).abs() > 0.5);
    if (heightChanged || widthChanged) {
      setState(() {
        _height = height;
        _width = width;
      });
    }
  }

  void _onKeyDown(web.KeyboardEvent event) {
    final root = _root;
    if (root == null) return;
    final isSelectAll = (event.metaKey || event.ctrlKey) &&
        !event.altKey &&
        !event.shiftKey &&
        event.key.toLowerCase() == 'a';
    if (!isSelectAll) return;
    final selection = web.window.getSelection();
    if (selection == null) return;
    event.preventDefault();
    event.stopPropagation();
    final range = web.document.createRange()..selectNodeContents(root);
    selection
      ..removeAllRanges()
      ..addRange(range);
  }

  void _onWheel(web.WheelEvent event) {
    final root = _root;
    final scrollable = Scrollable.maybeOf(context);
    if (root == null || scrollable == null) return;
    forwardMarkdownWheelDelta(
      event: event,
      root: root,
      position: scrollable.position,
    );
  }

  void _onCopy(web.ClipboardEvent event) {
    final selection = web.window.getSelection();
    if (selection == null || selection.isCollapsed) return;
    final data = event.clipboardData;
    if (data == null) return;
    event.preventDefault();
    data.setData('text/plain', selection.toString());
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
      _copyFeedbackTimer?.cancel();
      _copyFeedbackTimer = Timer(const Duration(seconds: 2), () {
        if (mounted && copy.isConnected) copy.textContent = 'Copy';
      });
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
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final maxWidth = constraints.maxWidth;
          if (maxWidth != _lastMaxWidth) {
            _lastMaxWidth = maxWidth;
            final root = _root;
            if (root != null) {
              if (maxWidth.isFinite) {
                root.style.maxWidth = '${maxWidth}px';
              } else {
                root.style.removeProperty('max-width');
              }
              WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
            }
          }
          return SizedBox(
            width: widget.fitContent ? _width : null,
            height: _height,
            child: HtmlElementView.fromTagName(
              tagName: 'div',
              onElementCreated: _attach,
            ),
          );
        },
      );
}

/// Replace only the changed run of top-level blocks in [root]. While a
/// response streams this is usually just the last block, so earlier
/// paragraphs keep their DOM nodes, selection and copy-button state.
void patchMarkdownBlocks(
    web.Element root, List<String> previous, List<String> next) {
  final diff = diffBlocks(previous, next);
  for (var i = diff.previousEnd - 1; i >= diff.start; i--) {
    root.children.item(i)?.remove();
  }
  final anchor = root.children.item(diff.start);
  for (var i = diff.start; i < diff.nextEnd; i++) {
    final template = web.document.createElement('template')
        as web.HTMLTemplateElement
      ..innerHTML = next[i].toJS;
    final block = template.content.firstElementChild ??
        (web.document.createElement('p')..textContent = next[i]);
    root.insertBefore(block, anchor);
  }
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
  overflow-wrap: anywhere; user-select: text; -webkit-user-select: text; cursor: auto; outline: none; }
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
  padding: .25em .75em; font-size: .8em; color: var(--smd-muted); border-bottom: 1px solid var(--smd-border);
  user-select: none; -webkit-user-select: none; }
.syntila-md .syntila-md-code-bar button { font: inherit; color: inherit; background: none; border: 0; cursor: pointer; }
.syntila-md pre { margin: 0; padding: .75em; overflow-x: auto; background: var(--smd-code-bg); }
.syntila-md pre code { background: none; padding: 0; font-size: .85em; white-space: pre; }
.syntila-md .smd-kw { color: var(--smd-kw); } .syntila-md .smd-str { color: var(--smd-str); }
.syntila-md .smd-num { color: var(--smd-num); } .syntila-md .smd-ttl { color: var(--smd-ttl); }
.syntila-md .smd-com { color: var(--smd-muted); font-style: italic; }
''';
