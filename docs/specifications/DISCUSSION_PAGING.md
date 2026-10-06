# Discussion paging contract v1

`GET /api/workstreams/:id/discussion-messages` authorizes access on every request and
returns bounded pages. `limit` defaults to 50 and accepts integers from 1 to
100. `before` and `after` are mutually exclusive opaque cursors.

Without a cursor, the endpoint returns the newest messages. `before` returns
older messages; `after` returns newer messages. Every response orders messages
chronologically by `(created_at, id)`, including equal timestamps.

```json
{
  "schemaVersion": 1,
  "messages": [],
  "nextCursor": null,
  "newestCursor": null
}
```

`nextCursor` continues in the requested direction and is null when that page
has no continuation. `newestCursor` identifies the newest returned message;
an empty forward page retains its incoming anchor. Cursors encode version 1,
Workstream identity, creation timestamp, and message ID. They are pagination
positions, not authorization tokens. Malformed, unsupported, cross-Workstream,
or conflicting cursors and invalid limits produce HTTP 400. All cursor values
are bound SQL parameters. Clients must treat cursors as opaque.

Message fields, authored Markdown, references, send/edit endpoints, and
persistent schema remain unchanged. No database migration is required. The AX
and Cloud changes should ship together: AX requires the versioned envelope.
`AxDataSource.loadDiscussionPage` exposes this contract; custom Dart data sources
must implement it. The retained `loadDiscussionMessages` method now returns the
newest page, rather than unbounded history. AX loads additional history through
scroll-triggered pagination. Reconnects with a known newest cursor fetch only
forward pages and never refetch loaded older pages. Reopening additionally
reconciles the newest window for edits; creation-order cursors do not track edits.

Realtime contract 1.1 adds ID-only `discussion.created` and `discussion.updated`
[signals](REALTIME_SYNCHRONIZATION.md). Creation uses the existing forward cursor.
For edits, `GET /api/discussion-messages/:id` returns `{ message }` after current
Workstream view authorization (404 when missing; access denied when unauthorized).
It preserves authored Markdown and returns parsed references. AX
`loadDiscussionMessage(messageId:)` merges that single entity when already cached,
including in older pages, without changing either pagination cursor. Custom AX
data sources must implement the lookup. The paging envelope remains version 1.
