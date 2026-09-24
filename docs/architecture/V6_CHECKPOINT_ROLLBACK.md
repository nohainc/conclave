# V6 Checkpoint and rollback lifecycle

Stateful Workstream completion is finalized by the managed Checkout runtime.
The runtime captures a bounded diff and status before deciding whether the
Checkout changed.

- A dirty successful Checkout creates one managed commit and updates its
  revision metadata.
- A clean successful Checkout records a no-change result without creating a
  commit.
- Failure and cancellation reset to the supplied base revision and run
  controlled `git clean` recovery for generated untracked files.
- If reset or cleanup fails, bounded diagnostics are persisted locally and the
  Checkout is reported as `recovery_required`/quarantined.

Cloud records successful revisions as Workstream Checkpoints, maintains the
current checkpoint relation, stores bounded diff artifacts, and releases the
execution lease after finalization. This ensures the next Work Request starts
from a known revision or an explicit recovery state.
