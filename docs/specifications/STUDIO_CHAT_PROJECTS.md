# Conclave AX Chat and Project Model

**Status:** Proposed product model  
**Scope:** Conclave AX, Conclave Cloud API, domain navigation

## 1. Product principle

Conclave AX should feel familiar to users of modern AI chat applications.

The primary user surface is **conversation**, while Conclave orchestration remains visible and inspectable without forcing users to operate a workflow dashboard for every request.

Conclave AX should support:
- Projects;
- Chats;
- conversational requests/follow-ups;
- visible active Runs;
- approvals/questions from Conclave;
- artifacts/results;
- advanced execution details on demand.

## 2. Hierarchy

```text
Workspace
  -> Project
      -> Chat
          -> Messages
          -> Goal 1 -> Run(s)
          -> Goal 2 -> Run(s)
          -> ...
```

A Project groups related Chats and shared execution context.

A Chat is a durable human-facing conversation.

A Goal is an orchestration object created from an actionable request inside a Chat.

A Chat can therefore contain multiple Goals over time.

## 3. Project

A Project may define shared context such as:

- name/description;
- repositories/resources;
- default Hosts/Workers;
- default quality preset;
- Worker configuration;
- budget;
- environment;
- project instructions;
- retention/security policy.

Example:

```text
Project: Conclave AX

Chats:
- Host/Worker architecture
- Authentication design
- Cloud deployment
- Conclave AX UX
```

This is more useful than creating a separate Project for every request.

## 4. Chat

A Chat stores ordered Messages and references to Goals/Runs initiated from those messages.

Message actors include:
- human User;
- Conclave;
- AI Worker result surfaced to user;
- system/status;
- approval/request-for-input.

The user should normally see a concise Conclave response, not raw Worker chatter.

Detailed worker messages, candidates, reasoning artifacts, findings, and execution logs are accessible through expandable Run details.

## 5. From message to Goal

Example:

```text
User:
"Review the authentication architecture and propose improvements."
```

Cloud decides this is actionable and creates:

```text
ChatMessage M-20
  -> Goal G-10
      -> Run R-10
```

Conclave AX immediately shows an execution card inside the conversation:

```text
Conclave AX
Reviewing authentication architecture...

Research       2/2 complete
Synthesis      running
Review          waiting

[Open run]
```

When complete, the same conversation receives the final response and artifact links.

## 6. Follow-up behavior

A follow-up may:

### Continue the existing Goal
Example:
"Use option B, but keep the current database."

If the previous Run is awaiting user input/approval, the message resumes that Goal/Run.

### Create a new Goal in the same Chat
Example:
"Now implement the selected architecture."

The Chat remains the same, but a new Goal/Run is created and can reference prior accepted Artifacts/Decisions.

### Conversational-only message
Example:
"Why did reviewer B disagree?"

No new execution Goal is required. Cloud can answer from persisted run state or assign a small Worker Task if needed.

The Lead/intent logic proposes which behavior applies; Core validates the transition.

The normative transition and scoped context rules are defined in
[Chat Intent and Scoped Context](CHAT_INTENT_CONTEXT.md).

## 7. Conclave AX layout

Recommended desktop/web layout:

```text
┌─────────────────────────────────────────────────────────┐
│ Workspace ▾          Search             Agents  Profile │
├────────────────┬────────────────────────────────────────┤
│ + New chat     │                                        │
│                │ Project: Conclave AX                   │
│ PROJECTS       │                                        │
│ ▾ Conclave AX  │ User                                   │
│   Host design  │ Review Worker architecture...          │
│   Auth design  │                                        │
│   Cloud setup  │ Conclave AX                            │
│                │ Researching with 2 workers...          │
│ ▾ Earth        │ [Run progress]                         │
│   Scheduler    │                                        │
│                │ Conclave AX                            │
│                │ Here is the verified result...         │
│                │ [Architecture.md] [Open run]           │
│                │                                        │
│                │ ────────────────────────────────────── │
│                │ Ask Conclave AX...                     │
└────────────────┴────────────────────────────────────────┘
```

On small screens the Project/Chat sidebar collapses.

## 8. Run details

Run details are secondary but first-class.

Opening a Run shows:
- phases/tasks;
- selected Agents/Workers;
- candidate Attempts;
- synthesis/evaluation;
- timeline;
- findings;
- verifications;
- artifacts;
- token/cost/subscription usage;
- machine evidence;
- approvals;
- controls.

This preserves Conclave's auditability without turning the main UI into a workflow-engine console.

## 9. Chat context

Chat history is not blindly sent to every Worker.

Conclave builds task context from:
- current user message;
- accepted prior Decisions/results in the Chat;
- relevant Artifacts;
- Project context;
- explicit user-selected references.

Context assembly should prefer durable accepted state over copying the entire transcript.

This reduces token cost and prevents old speculative discussion from silently becoming authoritative.

## 10. Collaboration

Multiple Workspace users may use the same Project.

For v1, a Chat has one active conversational stream shared by authorized Project members. Messages show the author.

When one User creates/controls a Goal, other authorized members can observe it. Pause/cancel/approve actions are permission checked and attributed.

Later features may add:
- mentions;
- comments on artifacts/findings;
- presence;
- branches/forks of Chats.

Do not require those for v1.

## 11. Search and history

Conclave AX search should eventually cover:
- Projects;
- Chat titles/messages;
- Goals;
- completed results;
- artifacts/findings.

The user should be able to return to a Chat weeks later and continue from accepted project/run state.

## 12. UX invariant

> Chat is the primary interaction surface; Goal/Run state is the authoritative execution surface.

The UI may look like an AI chat application, but completion, verification, costs, and workflow state never depend on unstructured chat text alone.
