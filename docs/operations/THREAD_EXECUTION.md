# Chat and Work execution

AI Chat is selected in the Thread **Work** composer. The **Chat** discussion
tab stores human/team messages separately. Both surfaces preserve Markdown source.
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

Older signed Profiles without qualified `thread_read` capability fail closed
for Chat; publish a qualified successor rather than editing a signed release.
Antigravity's current starter cannot enforce read-only Thread access and is
not eligible for Chat. It may still run Work. Release qualification and live
provider acceptance remain required; see [regression coverage](../acceptance/CHAT_WORKFLOW.md).
