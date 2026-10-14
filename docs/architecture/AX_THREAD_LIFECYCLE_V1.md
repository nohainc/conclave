# AX Thread interaction lifecycle V1

Phase 5 moves interaction side effects out of ThreadPage rendering callbacks.

## Scheduling ownership

- Chat and Work use separate `ScrollController` instances. Each controller
  keeps its own follow-latest flag and deferred follow operation.
- Cache snapshots, normalized activity notifications, and tab changes request a
  follow pass. Timeline builders only describe the current snapshot; they do
  not schedule scrolling.
- Composer alignment is requested by controller changes, dependency changes,
  tab changes, and the post-layout reveal of restored Thread state. Composer
  builders do not schedule alignment.
- Older-page anchor restoration is also deferred, but is guarded by the same
  interaction generation as the Thread navigation lifecycle.

## Navigation generation

`_interactionGeneration` changes whenever the State switches Thread and when it
is disposed. Every deferred post-frame operation captures the generation that
created it. A callback from an earlier Thread therefore cannot jump a current
scroll position, realign a current composer, reveal stale content, or restore
an older-page anchor.

Cache and presentation subscriptions are detached and reattached by
`ThreadPresentationController.attach`, whose own generation fence prevents
notifications from an inactive Thread from updating the active projection.

## Draft and focus safety

Asynchronous view-state restoration only fills an empty composer. It never
overwrites non-empty input that the user entered while the restore was in
flight, and it does not clear a draft when Work submission fails. Explicit
Thread navigation may clear the old Thread's draft before restoring the new
Thread's saved draft; stale restore completions are rejected by both the view
state and interaction generations.

## Required regression coverage

Lifecycle tests should cover rapid tab changes, Thread replacement, history
deletion/archive events, reconnect/replay, older-page insertion, incoming Chat
messages, incoming Worker activity, and failed Work submission while a draft is
present. A terminal or stale callback must never reopen a scroll position or
replace composer text from another Thread.
