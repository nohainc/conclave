# V6 Chat to Workstream Migration

V6 treats Chat as historical discussion data, never as an execution authority.
The preferred development path is a clean v6 reset. When fixtures or an
explicit dataset must be preserved, migration creates one Workstream per Chat,
migrates human-authored messages into Discuss, and records historical Run IDs
as Workstream activity references.

The mapping preserves Chat and message IDs. It does not turn a Chat message
into a Work Request, does not resume a Run automatically, and does not infer
execution intent from natural language. New execution begins only from the
Workstream Work composer and explicit Run action.

The active product uses Workstreams as the Project navigation surface. Legacy
Chat routes may remain readable for historical links during development, but
the normal Chat composer is discussion-only and exposes no Worker, Workspace,
Account, model, or execution controls.
