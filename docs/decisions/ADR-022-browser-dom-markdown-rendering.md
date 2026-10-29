# ADR-022: Browser-DOM Markdown Rendering in the AX Web App

**Status:** Accepted (default on web; opt out with `--dart-define=SYNTILA_HTML_MARKDOWN=false`)
**Date:** 2026-10-29
**Normative for:** `apps/app/lib/src/features/common/html_markdown/`, the
HTML branch of `SyntilaMarkdownBody`.

## 1. Context

Conversation Markdown is rendered with `flutter_markdown_plus`. Tables, code,
text selection, and future math/diagram content are limited compared to what
the browser renders natively. The AX app ships only as Flutter Web, so the
browser DOM is already available; no embedded browser or iframe is needed.

## 2. Decision

Render conversation Markdown as sanitized HTML in an `HtmlElementView`
(`HtmlElementView.fromTagName`). This is the default on web; builds with
`--dart-define=SYNTILA_HTML_MARKDOWN=false` keep the widget renderer. Flutter keeps all application
state; the DOM is a pure view of message text.

- Markdown is parsed in Dart (`markdown` package, GFM) and serialized by
  `renderMarkdownHtml` from the AST through a tag/attribute allowlist.
  Parser HTML output is never used.
- Raw HTML in authored content (inline or block) is emitted as escaped text.
- Links keep an `href` only if `validatedMarkdownLink` accepts it; clicks are
  intercepted and routed to Flutter's existing open-link path.
- Images render as their alt text; authored content loads no remote resources.
- Code highlighting reuses `SyntilaSyntaxHighlighter.parseTokens`; token
  classes map to a fixed `smd-*` set. Code-block copy uses the browser clipboard.
- Theme tokens are passed as CSS custom properties; one shared stylesheet is
  injected once.
- Wheel events inside a message platform view are forwarded to the enclosing
  Flutter `Scrollable` (unless consumed by horizontal scrolling inside a wide
  table or code block), and pointer/keyboard selection (`pointerdown`,
  `selectionchange`, `Cmd/Ctrl+A`) is scoped to the active message root.
- Notes (blank-line spacers) and callers needing Flutter selection callbacks
  keep the widget renderer.

## 3. Consequences and open work

- One platform view is created per message. As a follow-up, replace this with a single DOM renderer for the conversation area (append /
  update-by-id API, preserved scroll and selection during streaming).
- Streaming updates are block-incremental: `renderMarkdownBlocks` yields one
  HTML string per top-level block and `patchMarkdownBlocks` replaces only the
  changed run (common prefix/suffix kept), so finished blocks keep DOM
  identity and selection. Parsing is still whole-message per update.
- KaTeX/Mermaid would add third-party JS to `web/`; that requires a separate
  security review (CSP, sandboxing for Mermaid SVG).
- Screen-reader navigation and full keyboard accessibility across platform
  views are not yet verified.
- Native clients (if built) could reuse `renderMarkdownHtml` output in a
  WebView.
