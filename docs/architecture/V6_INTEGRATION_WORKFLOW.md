# V6 Workstream Integration Workflow

Integration is a Workstream-owned state machine that provides a controlled
route from execution output back to the Project base:

1. publish the managed branch;
2. create a GitHub Pull Request when the repository supports it;
3. review and mark merge-ready against the recorded base revision;
4. merge, or export a patch artifact when PR integration is unavailable;
5. mark the Workstream integration completed.

Project owner policy determines who may perform integration actions. A Project
collaborator may contribute execution output, but cannot merge or export it
unless the policy explicitly grants that capability. Unauthorized actions are
rejected before provider calls.

The integration record stores the Workstream, Project, requester, provider,
branch, base/head revisions, PR metadata, patch artifact, status, and errors.
PR creation and merge revalidate the recorded base revision. If the Project
base moved, the state becomes `conflict` and the user must rebase/review before
continuing. A repeated publish is idempotent for the same managed branch.

GitHub is preferred for connected repositories. Patch export remains an
explicit fallback and is itself recorded as a Workstream result; no output is
silently applied to the Project base.
