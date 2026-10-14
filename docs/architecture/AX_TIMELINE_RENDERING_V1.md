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
new extent after older entries are prepended. Following the latest entry is
still conditional on the user being near the bottom, and follow callbacks are
coalesced per tab.

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
does not build the complete list. Existing Thread layout tests remain available
for responsive Chat/Work and composer-placement follow-up.
