# ADR-022: Browser-DOM Markdown Rendering in the AX Web App

**Status:** Proposed (prototype behind a compile-time flag)
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
(`HtmlElementView.fromTagName`), opt-in via
`--dart-define=SYNTILA_HTML_MARKDOWN=true`. Flutter keeps all application
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
- Notes (blank-line spacers) and callers needing Flutter selection callbacks
  keep the widget renderer.

## 3. Consequences and open work

- Prototype creates one platform view per message. Before enabling by default,
  replace this with a single DOM renderer for the conversation area (append /
  update-by-id API, preserved scroll and selection during streaming).
- Streaming currently re-renders the whole message per update.
- KaTeX/Mermaid would add third-party JS to `web/`; that requires a separate
  security review (CSP, sandboxing for Mermaid SVG).
- Cross-message selection, keyboard focus, and accessibility in the DOM view
  are not yet verified.
- Native clients (if built) could reuse `renderMarkdownHtml` output in a
  WebView.
