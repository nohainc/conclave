# AX Work Rendering V1

Work request cards keep request content, activity state and response content on
separate rendering boundaries.

## Rendering boundaries

- Request prompt Markdown is owned by `_MemoizedWorkMarkdown` and changes only
  when its source text or fit mode changes.
- Response Markdown uses the same boundary and retains the existing
  `(requestId, responseText)` identity key, so changed response text replaces
  stale selection handles deliberately.
- Activity and elapsed-time updates continue through the request-specific
  activity selector and `AxLiveTicker`. Activity history is already bounded in
  the store and the visible trail keeps only the active item plus the latest
  completed entries.
- Work request/status changes still rebuild the card projection when the
  authoritative request snapshot changes; activity-only updates do not
  reparse unchanged Markdown.

Frequent replaceable provider updates remain throttled by
`AxWorkActivityStore`. Terminal activity and lifecycle changes remain
immediate. No Markdown source, tool input, credentials or unrestricted
provider output is copied into the rendering cache.

## Compatibility

This is an internal Flutter rendering change. Work history, activity-store and
realtime contracts are unchanged. The memoization boundary is intentionally
content-based rather than time-based, so a response is always replaced when
its source text changes.

## Acceptance evidence

The existing Work rendering regression verifies that previously rendered
responses retain their `SyntilaMarkdownBody` element and content key while
optimistic requests and live progress are inserted around them. Focused AX
activity, presentation-controller and Work history tests cover selector
isolation, bounded activity behavior and lifecycle updates.
