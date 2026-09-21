# Interactive Web / Cloud AI Workers

**Status:** Proposed architecture  
**Scope:** Conclave AX Cloud, Worker Connections, remote MCP/apps/connectors, Studio

## 1. Purpose

Conclave AX must support AI workers that run inside subscription-backed web/cloud AI applications, not only provider APIs or local agents.

Examples include browser/web chat products where the user already pays for access and where the AI can use connected apps, plugins, connectors, or MCP tools.

This transport is especially useful for:
- research;
- architecture/design;
- brainstorming;
- requirements analysis;
- plan critique;
- independent review;
- synthesis;
- other read-only or reasoning-heavy work that does not require direct repository mutation.

## 2. Preferred integration model

The preferred architecture is **tool-connected interactive execution**, not browser DOM automation.

Conclave AX exposes a remote app/connector/MCP surface that an AI web product can connect to. The AI remains in its native web chat while Conclave provides tools such as:

- `conclave.register_session`
- `conclave.claim_task`
- `conclave.get_task`
- `conclave.get_context`
- `conclave.get_next_message`
- `conclave.submit_candidate`
- `conclave.submit_finding`
- `conclave.submit_result`
- `conclave.report_status`
- `conclave.release_task`

The exact tool names may change; the invariant is that the web AI uses Conclave's supported tool/app interface instead of Conclave automating the consumer website.

## 3. Interactive session model

An Interactive Web Worker is a Worker plus a Connection and a durable Conclave-side session.

```text
Worker
  -> Connection(web_app)
      -> WorkerSession
          -> Task claim
          -> mailbox/messages
          -> Candidate Attempt
```

A WorkerSession records:
- Conclave session id;
- Worker id;
- provider/surface identity;
- organization/project/run/task;
- external conversation reference when the provider exposes one;
- optional user-supplied conversation URL/reference;
- status;
- created/last-seen timestamps;
- lease/expiry;
- capability snapshot;
- tool/app version;
- current Attempt id.

Conclave must not depend on access to an internal provider chat id. If the provider does not expose one, Conclave's own session id is authoritative.

## 4. Pull mailbox, push when supported

Conclave must not assume that it can inject arbitrary new messages into an existing third-party web chat.

The baseline protocol is a durable mailbox:

```text
Conclave creates message/task
       |
       v
WorkerSession mailbox
       |
       v
web AI calls get_next_message / get_task
       |
       v
AI reasons in native chat
       |
       v
AI submits result/tool call
       |
       v
Conclave validates and may enqueue follow-up
```

When a provider later exposes a supported callback, event, background-agent, or session API that permits server-initiated continuation, the Connection adapter may implement true push while preserving the same WorkerSession abstraction.

"Push supported" is therefore a Connection capability, not a Core assumption.

## 5. Conversation continuity

A web worker may use:
- one fresh chat per Attempt;
- one chat for the lifetime of one Task;
- one persistent chat for a Project/Role when policy explicitly allows it.

Conclave stores the continuity policy and session reference.

Independent research/review should prefer a fresh isolated chat. Long-running synthesis may reuse the task chat when beneficial.

The web AI's native conversation history is helpful context, but Conclave's persisted Task, Attempt, Artifact, Event, and Decision records remain the source of truth.

## 6. Structured result handoff

The worker should not be required to make its entire natural-language chat match a Conclave JSON schema.

Instead:
1. the AI performs normal reasoning in the web conversation;
2. when ready, it calls the Conclave submit tool/app action;
3. the tool payload uses the same versioned Conclave result contract as every other Worker transport;
4. Core validates and persists the result;
5. Conclave may respond with accepted / rejected / needs-more-work and enqueue the next message.

This preserves natural web-chat ergonomics while keeping machine-readable orchestration.

## 7. Subscription economics

Interactive web workers usually consume the user's existing subscription/plan allowance rather than Conclave API-token spend.

Conclave records:
- billing mode = `subscription`;
- provider/surface;
- executions/session time;
- quota/rate-limit signals when observable;
- monetary cost = unknown/zero-at-point-of-use unless the provider exposes a useful value.

Conclave must never describe subscription usage as literally free.

## 8. Connection capabilities

A `web_app` Connection advertises capabilities such as:

- `remote_tools`;
- `structured_submit`;
- `conversation_reference`;
- `server_push`;
- `background_execution`;
- `file_access_via_provider_apps`;
- `web_search`;
- `user_approval_required`.

Routing can use these capabilities.

Example: a web worker that has web search and connected business apps may be an excellent Researcher even if it has no repository-write capability.

## 9. Conclave AX connector/app

Conclave should eventually ship an official remote connector/app/MCP server usable from supported AI products.

It authenticates the user to Conclave AX and scopes access to that user's organizations/projects.

The connector exposes only bounded tools. It does not expose raw D1/R2, credentials, unrestricted runtime operations, or arbitrary cross-project data.

The AI can use the connector to:
- discover work assigned to that Worker;
- retrieve bounded context;
- submit results/findings;
- receive follow-up instructions through the mailbox;
- ask Conclave for clarification/status.

## 10. Optional browser companion

A browser extension/companion that assists with unsupported web AI products may be explored later, but it is not the primary architecture.

If implemented, it must not:
- steal/reuse provider cookies outside the browser;
- bypass provider controls;
- scrape hidden/private APIs;
- pretend browser automation is a stable provider contract.

It should preferably assist the user with copy/paste/session linking rather than silently controlling the website.

## 11. Multi-worker use

Interactive web workers participate in the same Execution Policy as API/local workers.

Example:

```text
Architecture Task
  -> ChatGPT web Worker
  -> Claude web Worker
  -> Gemini web Worker
  -> Synthesizer
```

Each candidate is a separate Attempt. Provider/web-surface diversity contributes to the recorded independence level.

This is particularly attractive for Exploration and High Assurance presets because several subscription-backed web workers may provide broad idea diversity at low incremental API cost.

## 12. Failure and availability

Interactive web workers can become unavailable because:
- the user closed the chat/device;
- subscription quota is reached;
- connector/app is disabled;
- provider requires approval;
- the session lease expires;
- the provider surface cannot continue without a user turn.

These are Worker availability/dependency failures, not content failures.

Policy may:
- wait for the web worker;
- notify the user;
- reroute to another web/local worker;
- fall back to a provider API.

## 13. First acceptance scenario

1. User configures two web workers with Conclave's connector.
2. Conclave creates an Architecture Task in `synthesize` mode.
3. Each web worker starts/links an isolated chat and claims one candidate Attempt.
4. Each pulls the same bounded task context.
5. Each independently submits a structured design candidate.
6. Conclave creates a Synthesis Task.
7. A third configured worker synthesizes the candidates.
8. Conclave persists candidates, disagreement analysis, selection rationale, cost/billing metadata, and the accepted result.

No provider API call is required for the two candidate workers.
