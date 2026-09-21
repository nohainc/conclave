# Independent Verification

Task completion is gated by a named verification policy. Core owns the gate; workers may submit review and verification results but cannot bypass it.

## Policies

- `standard`: independent review required; `blocker` and `major` findings block completion.
- `high`: independent review and an executable check required; `blocker` and `major` findings block completion.
- `critical`: independent review, executable check, and human approval required; `blocker`, `major`, and `minor` findings block completion.

`note` findings are informational. A blocking finding remains blocking while `open`, `reopened`, or `fixed`; it becomes non-blocking only after a re-review marks it `verified` or an authorized decision dismisses it.

## Isolation and fix loop

An independent review must use a different reviewer Worker from the implementation author and a different review context from the implementation context. A finding follows this lifecycle:

```text
open -> fixed -> verified
  \-> reopened -> fixed -> verified
```

Core refuses to mark a Task complete when required verification is missing or any blocking finding remains unresolved. Reopening a Task returns it to `pending`; the correction attempt and re-review must satisfy the gate again.

An Implementer correction only transitions a Finding to `fixed`. The independent Reviewer must return its ID in `resolvedFindingIds` on a subsequent passing `ReviewResult`; only then may Core transition it to `verified`. A passing review that omits a pending finding is not treated as implicit acceptance.
