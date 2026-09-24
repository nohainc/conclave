# V6 Discuss and Send to Work

Discuss is the human collaboration surface for a Workstream. It contains
messages, replies, references, author edits, and linked activity cards. A
discussion message is never an execution command, regardless of its wording.

## Send to Work

An authorized user may select one or more discussion messages and choose Send
to Work. The application opens the Work composer with the source messages
attached as references. This action creates or updates a draft only:

- it does not create a Work Request;
- it does not enqueue a Run;
- it does not reserve a Workspace, checkout, lease, Worker, or Account;
- the user must still review the draft and press Run.

The source message IDs remain attached to the draft so the resulting Work and
its audit trail can link back to the collaboration context. Multiple selected
messages are preserved in order and remain individually attributable.

## Completion notification

When Work completes, Discuss receives a compact activity event linking to the
Work result. The event summarizes the result and exposes the checkpoint,
changes, tests, and findings through the Work timeline. It is a notification,
not a second execution path.

Realtime updates must be authorized against the Workstream and Project before
they are appended to the discussion read model. Edits and new messages should
preserve ordering and source attribution when multiple collaborators are
connected.
