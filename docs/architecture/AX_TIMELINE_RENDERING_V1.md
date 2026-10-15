# AX Timeline Rendering V1

Status: Phase 2 implementation

## Rendering contract

Chat and Work history use the shared `AxTimelineContainer`. Each instance owns
one `CustomScrollView` and one independent `ScrollController`:

- Chat uses `chat-history-scroll` and `_chatHistoryController`.
- Work uses `work-history-scroll` and `_workHistoryController`.

Pagination controls, loading indicators, errors, and empty states are
`SliverToBoxAdapter` or `SliverFillRemaining` content. Timeline entries are
variable-height children of a keyed `SliverList`; no fixed item extent or full
history intrinsic measurement is used. Markdown, code blocks, and expandable
Work activity cards retain their natural heights.

## Identity and pagination

Chat message IDs and Work request IDs are used as stable `ValueKey`s. The
sliver delegate maps those keys back to their current item indexes so updates,
insertions, and pagination do not unnecessarily discard child state.

Older-page loading retains the existing anchor calculation: it records the
scroll offset and extent before the page is fetched, then compensates for the
new extent after older entries are prepended. Following incoming content is conditional on the user being near the bottom,
and follow callbacks are coalesced per tab. After the initial history load,
Chat anchors the first appended message; Work anchors a new request or the
response inside an existing request. Short content remains fully visible above
the composer. Content taller than the viewport aligns its beginning with the
top of the history viewport, rather than jumping to its end. The first anchor
is retained through response growth and subsequent arrivals until the reader
scrolls, so later updates cannot skip the opening of unread content. Older-page
prepends and Chat edits do not create incoming-message anchors. Anchors use
rendered positions and retain the existing virtualized list; keys are pruned
when their messages leave cached history.

The composer remains outside the timeline viewport in both tabs. Switching
tabs therefore does not transfer or reuse a scroll controller, and switching
Threads retains the existing controller lifecycle and saved view state.

## Compatibility

The scroll surface keeps the existing test and accessibility keys, pagination
callbacks, retry actions, activity-specific listeners, and data/cache APIs.
This is a client rendering change only; no Cloud, Workspace, Engine, or wire
protocol contract changes are required.

## Verification

The Work history and Discussion cache widget tests exercise the `CustomScrollView`
controllers, large histories, older-page loading, and viewport preservation.
The dedicated timeline test verifies that a 5,000-entry variable-height history
does not build the complete list. Incoming-message tests check Chat and nested
Work response anchors, response growth, subsequent arrivals, and short content;
a ThreadPage integration test checks both histories and manual-scroll preservation. Existing Thread layout tests remain available
for responsive Chat/Work and composer-placement follow-up.
