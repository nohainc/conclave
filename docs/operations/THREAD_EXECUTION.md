# Chat and Work execution

Opening a Space shows its description, when available, and an optional Thread
name field. Chat/Work tabs sit directly above the composers at the bottom;
the empty history area stays blank. The Space page's Chat composer always shows
its Markdown toolbar without a Show/Hide toggle, including in the single-tab
layout. **Create Thread** inside the name field
creates and opens a Thread without sending a message, and is disabled when the
trimmed name is empty. Names are limited to 22 characters.
The first nonempty Chat message or Work request also creates the Thread before
submitting. It uses the entered name, or the opening words of the request when
the name is empty; an oversized first word is truncated. The app then opens that Thread on the tab
used to send. Creation failures keep the draft. If creation succeeds but sending
fails, retry uses the same Thread. Existing Threads remain in the sidebar.

AI Chat is selected in the Thread **Work** composer. The **Chat** discussion
tab stores human/team messages separately. Both surfaces preserve Markdown source.
Own Chat messages and Work prompts longer than four preview lines start collapsed.
Use **Show more** to view the full Markdown and **Hide more** to collapse again.
Copy and edit actions retain the complete source.
Chat and Work composer Send, Preview/Write, and Show/Hide Markdown controls
use the theme text color. Work keeps its Markdown toolbar hidden in both layouts. The expanded Markdown toolbar has no top divider.
In both composers, Enter sends and Shift+Enter inserts a new line. Ctrl/Cmd+Enter
also sends. Editing an existing discussion retains Enter for a new line and
Ctrl/Cmd+Enter to save.
Selecting a different Space loads its Threads into the sidebar. Manual
expansion/collapse is preserved during background refreshes.

1. Open the Space Workflows surface and configure a Ready Worker/model for
   **Chat** and **Work**. These bindings are independent and may use different
   registered Workers.
2. Choose **Chat** for explanation, investigation or conversation. Its Profile
   must enforce read-only execution. Requests resume the Thread's Chat
   conversation without acquiring a mutation lease. Asking for implementation
   does not grant write access; select Work when changes should be performed.
3. Choose **Work** for implementation. It uses writable Thread policy,
   mutation coordination and fencing, and a separate durable conversation.
   The Space Workspace grant must permit the required repository access.
4. Inspect progress and Markdown results in Work history. Retry failed turns
   explicitly. History retains Direct for old `direct:v1` snapshots and Work
   for current `direct:v2`; the stored Workflow ID and binding remain `direct`.

| Step | Existing authority and coordination | Provider session scope |
| --- | --- | --- |
| Research | Read-only analysis; stateless Step | Request/Step |
| Plan | Read-only planning; stateless Step | Request/Step |
| Implement | Writable; stateful Thread Step | Request/Step, except Work's durable Thread conversation |
| Test | Read-only validation with authorized test commands; stateful Step | Request/Step |
| Verify | Read-only independent review; stateful Step | Request/Step |

Workflows containing stateful Steps retain one mutation lease for the request.
Chat has only its read-only stateless Step and never enters that coordination.
Chat and Work never share a provider session, even with the same Worker/model.

Deploy ordered migrations through `0008_codex_compatibility_approval_policy.sql`
using the [production provisioning runbook](PRODUCTION_PROVISIONING.md).

Cloud serves the authoritative Workflow catalog. If both the default selector
and composer menu still show Direct and omit Chat, the connected Cloud is running
the older catalog; deploy the updated Cloud after migrations, then reopen the
Thread. The default local launcher proxies this same hosted catalog.

Cloud owns Chat versus Work workflow eligibility. Legacy signed Profiles may
still contain a `capabilities` array for migration compatibility, but Cloud,
Workspace, and the Engine ignore that metadata. AGY Chat uses the signed
Profile's `--mode plan` mapping and Work uses its restricted `accept-edits`
mapping. Release qualification and live provider acceptance remain required;
see [regression coverage](../acceptance/CHAT_WORKFLOW.md).
