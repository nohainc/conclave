# Conclave AX Home Contract (v1)

## Overview

The Conclave AX **Home** surface is the personal collaboration and attention hub for a user across all their Projects.

Home is **not** a metrics dashboard of infrastructure counts (e.g. number of Projects, connected Workspaces, ready Workers, or idle execution queues). Infrastructure and entity management reside in their dedicated navigation areas (Projects, Workspaces, Workers, Runs).

Instead, Home answers three fundamental questions for the user:
1. **What needs my attention?**
2. **What was I working on with my team and AI?**
3. **What is new in Conclave and in my connected AI tools?**

```text
HOME
│
├── 1. For You
│    └── Actionable items requiring or deserving attention
│
├── 2. Continue Working
│    └── Recent relevant Workstreams with collaboration context
│
├── 3. What's New
│    └── Conclave product release updates and feature announcements
│
└── 4. AI Updates
     └── Model and capability updates relevant to available Workers
```

---

## The Four Core Responsibilities

### 1. For You (Triage Surface vs Notification Center)
- **Distinct Responsibilities:**
  - **Notification Center:** Answers *"What happened?"* Full chronological timeline of events, reads/unreads, and historic notifications.
  - **Home ("For You"):** Answers *"What should I care about?"* A strictly bounded (max ~5 items) triage surface displaying only items that demand the user's active attention or decision.
- **Home Selection & Multi-Factor Ranking Algorithm:**
  1. **Priority category** (Project invitations → Input/Approval required → Failed executions → Worker/credential issues → Workspace connectivity → Completed reviews → General findings/info).
  2. **Unread state** (Unread items are prioritized over already-viewed items).
  3. **Actionability** (Items requiring human action/decision e.g. Accept/Decline, Review, Fix rank ahead of passive informative items).
  4. **Recency** (Newer items rank ahead of older items when category, unread state, and actionability are identical).
- **Navigation & CTA:**
  - Explicit header CTA: `View all notifications →` opening the full Notification Center.
  - Category badge count showing the total number of attention items.
- **Card Structure:**
  - Semantic category chip (e.g. `Project invitation`, `Needs your input`, `Failed execution`, `Worker needs attention`, `Workspace offline`, `Completed`).
  - Relative timestamp (e.g. `8 minutes ago`, `24 min ago`).
  - Item Title and contextual Subtitle (e.g. `Julia invited you to "Family Travel"`, `Owner · 8 minutes ago`).
  - Contextual action buttons (`Decline` / `Accept`, `Review →`, `Open →`, `Inspect →`, `Fix →`, `Connect →`).
- **Absence Behavior:** If nothing requires attention, the section renders `const SizedBox.shrink()` (zero filler/empty placeholder text like `"Nothing needs your attention"`).

### 2. Continue Working (Phase 8 & Phase 9: Recent-Work Ranking)
- **Purpose:** Fast resumption of ongoing collaborative work in context. Projects are broad; the true return destination is the active Workstream/conversation.
- **Capacity:** Shows 3–5 recent Workstreams.
- **Card Structure:**
  1. **Project Name:** Uppercase tracked label (e.g., `CONCLAVE DEVELOPMENT`, `WEBSITE`).
  2. **Workstream Title:** Prominent bold title (e.g., `Worker Sessions`, `Landing Page`).
  3. **Collaborators + Relative Time:** Context badge indicating who is working together and when (e.g., `ChatGPT · 23 min ago`, `You + Gemini · Yesterday`).
  4. **Last Message / Work Quote:** Italicized discussion snippet or decision quote (e.g., `"We should persist the..."`, `"The hero should..."`).
  5. **Direct CTA:** `Continue →` button navigating straight into the Workstream conversation (`AxNavigation.workstream(projectId, workstreamId)`).
- **Recent-Work Ranking Engine (`AxRecentWorkRanker`):**
  - **Does NOT use naive `updatedAt DESC`:** Background synchronization, metadata polls, or entity updates do not push irrelevant workstreams to the top.
  - **Ranking Factors:**
    1. **Unresolved state (+1000 pts):** Active runs or workstreams waiting for human decisions.
    2. **Recent user participation (+500 pts):** User authored messages or direct contributions.
    3. **Recent worker response (+250 pts):** AI Workers replied to requests in this conversation.
    4. **Direct membership (+100 pts):** User is an active collaborator/owner on the parent project.
    5. **Meaningful conversation recency decay (up to +500 pts):** Time decay applied strictly to actual human and worker messages.
  - **Exclusion Filters:**
    - ❌ Archived Projects
    - ❌ Archived Workstreams
    - ❌ Deleted resources
    - ❌ Inaccessible / non-member resources
- **Absence Behavior:** Omitted if no project or workstream history exists.

### 3. What's New
- **Purpose:** Product updates, capability announcements, and changelogs.
- **Characteristics:**
  - Benefit-first descriptions (not git commits)
  - Human-readable release date
  - Direct deep-links to try new features (`Learn more →`)
  - Targetable audience / per-user read state tracking

### 4. AI Updates
- **Purpose:** Relevant model and capability changes for supported AI Workers.
- **Relevance Filter:** Scoped strictly to the Workers connected or available to the user's projects (e.g., ChatGPT model upgrades shown only to users with ChatGPT Workers enabled).
- **Not Generic AI Industry News:** Covers only changes that directly affect what the user can execute inside Conclave AX (e.g., *"GPT-5 is now available in your ChatGPT Worker"* vs generic press announcements).

---

## Established-User Home Invariants & Removals

The following legacy concepts are **prohibited** from established-user Home:
- ❌ Projects count metric card
- ❌ Workspaces count metric card
- ❌ Ready Workers count metric card
- ❌ Recent Projects plain list (replaced by *Continue Working* workstreams)
- ❌ Permanent `"No active Runs"` card
- ❌ Static `"Nothing needs your attention"` filler
- ❌ `"Archived Projects"` header button
- ❌ Generic `"Your execution capacity at a glance"` subtitle
- ❌ Onboarding / Getting Started cards mixed into the dashboard

---

## Clean Separation of Home Surfaces

```text
HomePage (Dispatcher)
    │
    ├── isNewUser == true  (projects.isEmpty)
    │     └── NewUserHome
    │           ├── (Priority if invitations.isNotEmpty) Join a Project card
    │           ├── ("or" divider if invitations.isNotEmpty)
    │           ├── Create your first Project card
    │           ├── How Conclave AX works (value foundation cards)
    │           └── Advanced local execution (Want to use AI or tools running on your computer?)
    │
    └── isNewUser == false (projects.isNotEmpty)
          └── EstablishedUserHome
                ├── 1. For You (attention items + pending invitations)
                ├── 2. Running Now (if active runs)
                ├── 3. Continue Working (active workstreams)
                ├── 4. What's New in Conclave (product updates)
                └── 5. AI Updates (scoped model updates)
```

### 1. NewUserHome
- **Condition:** Active when `projects.isEmpty`.
- **Experience & Onboarding Hierarchy:**
  ```text
  Create / Join Project
          ↓
  Collaborate
          ↓
  Add AI
          ↓
  Advanced local execution if required
  ```
  - Dedicated header: `Welcome to Conclave AX` / `Bring your people and AI together.`
  - **Priority Invitation Card** (when `invitations.isNotEmpty`):
    - Displays `Join a Project` with count badge (*"You have N invitations."*).
    - Inlines invitations with direct `Accept` and `Decline` actions.
    - Followed by an `or` separator.
  - **Primary Project Action**:
    - `Create your first Project` (*"Start a shared space for people, conversations and AI."*).
    - `Create Project →` action button.
  - **How Conclave AX works** value foundation:
    - `People first`: Invite teammates, family, and collaborators to work together with shared AI.
    - `Private credentials`: Share AI access without exposing private keys.
    - `Shared conversations`: Maintain shared project context across members.
  - **Advanced Local Execution Path** (visually secondary at bottom):
    - Title: *"Want to use AI or tools running on your computer?"*
    - Description: *"Connect Conclave Workspace to make local Workers available to your Projects."*
    - Action: `Connect Workspace →`
  - Completely omits established dashboard sections (`For you`, `Continue working`, `What's new in Conclave`, `AI updates`).

### 2. EstablishedUserHome
- **Condition:** Active when `projects.isNotEmpty`.
- **Experience:**
  - **For You**: Prioritizes attention items, workstream input requests, and pending invitations.
  - **Running Now**: Conditionally visible when active runs exist.
  - **Continue Working**: Contextual workstreams with collaborators, snippet, and `Continue →` button.
  - **What's New in Conclave**: Official product updates.
  - **AI Updates**: Scoped AI capability news for available worker types.
  - Strictly omits onboarding cards and getting-started tutorials.

---

## Attention Item Domain Abstraction (Phase 7)

To keep `HomePage` and `_ForYouItemTile` decoupled from backend schemas, realtime event shapes, and navigation routing plumbing, Home utilizes a presentation domain abstraction:

```text
AxHomeAttentionItem
├── id: String
├── type: AxHomeAttentionType (projectInvitation, needsInput, approvalRequired, executionFailed, executionCompleted, workerProblem, workspaceProblem)
├── priority: int? (explicit priority override or derived default order)
├── title: String
├── description: String
├── projectId?: String
├── workstreamId?: String
├── workerId?: String
├── workspaceId?: String
├── timestamp?: DateTime
├── timestampDisplay?: String
├── primaryAction?: AxHomeAttentionAction (label, onPerform closure, isDestructive)
├── secondaryAction?: AxHomeAttentionAction (label, onPerform closure, isDestructive)
└── read: bool
```

### Decoupling Guarantees
1. **Pure Presentation Tile (`_ForYouItemTile`):**
   - The tile does not handle routing switches, invitation models, or backend-specific structures.
   - It exclusively invokes `item.primaryAction?.onPerform()` and `item.secondaryAction?.onPerform()`.
2. **Projector Projection (`AxHomeAttentionProjector.project(...)`):**
   - Transforms diverse inputs (invitations, background findings, system notifications) into normalized `AxHomeAttentionItem`s.
   - Binds concrete callback closures into `AxHomeAttentionAction` instances (`Accept`, `Decline`, `Review →`, `Inspect →`, `Fix →`, `Connect →`, `Open →`).
   - Applies the 4-factor prioritization algorithm (Priority Category → Unread Status → Actionability → Recency) and truncates to the top 5 items.

---

## Cached / Local Read Model Architecture (Phase 10)

Home is designed as a **pure projection** of already synchronized client-side state:
- **No Reload Storms on Navigation:** Navigating `Project A → Home → Project B → Home` consumes shared in-memory stores (`store.projects`, `store.workspaces`, `store.executionChanges`, `store.invitations`, `store.catalogs.workers`, `store.notifications`, `store.productUpdateReadStates`) via reactive `ListenableBuilder` and `AxQueryBuilder`.
- **Zero Independent Server Reloads:** Opening Home never triggers independent HTTP fetch bursts for entities that are already managed by Conclave's background sync engine.

---

## What's New & Product Update Lifecycle (Phases 11–15)

### 1. ProductUpdate Domain Model (Phase 11)
```text
AxProductUpdate
├── id: String
├── slug: String
├── title: String
├── summary: String
├── details?: String
├── category: AxProductUpdateCategory (feature, improvement, security, workflow, collaboration, workspace, worker)
├── publishedAt: DateTime / String
├── minimumAppVersion?: String
├── maximumAppVersion?: String
├── actionType?: String
├── actionTarget?: String
├── imageUrl?: String
├── audience: String (e.g. 'all', 'collaborators', 'developers')
├── status: AxProductUpdateStatus (draft, published, archived)
├── actionUrl?: String
└── learnMoreUrl?: String
```

### 2. Server-Driven Update Lifecycle (Phase 12)
- **Status Filtering:** Established-user Home only presents `published` updates (draft and archived updates are filtered out in standard production mode).
- **Version Compatibility:** Respects `minimumAppVersion` and `maximumAppVersion` constraints against the running AX client build.

### 3. Per-User Read State Tracking (Phase 13)
```text
AxUserProductUpdateState
├── userId: String
├── updateId: String
├── seenAt?: DateTime     (appeared on Home)
├── openedAt?: DateTime   (user opened full detail / changelog)
└── dismissedAt?: DateTime (user explicitly hid / dismissed update)
```
- **Unread Badge Calculation:** `AxProductUpdateService.computeUnreadCount(...)` counts published, version-compatible updates where `seenAt == null` and `dismissedAt == null`.
- **Badge Display:** Displays `What's new • 2` (or counter badge) next to the section title when unread updates exist.

### 4. Home Presentation for What's New (Phase 14)
- **Capacity:** Shows the top 2–3 newest published, non-dismissed updates (`AxProductUpdateService.getHomeUpdates(..., limit: 3)`).
- **Tile Elements:**
  1. Category badge pill (`[COLLABORATION]`, `[WORKFLOW]`, `[SECURITY]`, `[WORKSPACE]`, `[WORKER]`, `[FEATURE]`, `[IMPROVEMENT]`).
  2. Date format: e.g. `Oct 7`.
  3. Bold title and multi-line summary.
  4. `Learn more →` CTA button triggering the detail view or full changelog.
- **Empty-State Omission:** If no updates exist or all are dismissed, the section collapses completely (`const SizedBox.shrink()`) with **zero** filler text (never displays `"Nothing new."`).

### 5. Full What's New Surface (`AxWhatsNewDialog`, Phase 15)
- **Entry Point:** Header `See all` action button on Home.
- **Monthly Grouping:** Groups changelog entries chronologically by month and year (`October 2026`, `September 2026`, etc.).
- **Rich Changelog Items:** Displays expanded markdown/details, publication dates, category badges, dismissal action, and external/deep-link CTAs.

---

## AI Capability Updates as Distinct Domain Model (Phase 16)

AI and model capability changes are **distinct** from generic Conclave application releases. Model additions, deprecations, tool profile updates, and provider capability adjustments are modeled independently.

### 1. AiCapabilityUpdate Domain Model
```text
AxAiCapabilityUpdate
├── id: String
├── workerProfileId: String (e.g. 'chatgpt', 'gemini', 'claude', 'ollama')
├── provider?: String       (e.g. 'openai', 'google', 'anthropic', 'meta')
├── type: AxAiCapabilityUpdateType
│   ├── model_added
│   ├── model_removed
│   ├── model_deprecated
│   ├── capability_added
│   ├── capability_changed
│   ├── profile_updated
│   └── authentication_changed
├── modelId?: String          (e.g. 'gpt-4o', 'gemini-2.5-pro')
├── modelDisplayName?: String (e.g. 'GPT-4o', 'Gemini 2.5 Pro')
├── title: String
├── summary: String
├── publishedAt: DateTime / String
├── actionTarget?: String
└── minimumProfileVersion?: String
```

### 2. Presentation & Filtering on Home
- **Scoped by Active Workers:** When workers are configured in the user's workspace, Home filters AI capability updates to highlight relevant provider/worker capabilities.
- **Card Presentation (`_AiUpdateCard`):** Displays worker identity dot, worker name, category pill badge (e.g. `[MODEL ADDED]`, `[CAPABILITY ADDED]`), publication date (`Oct 7`), bold title, and concise summary.

---

## User-Relevant Worker Accessibility & Dynamic AI Update Filtering (Phase 17)

Home filters AI updates to show **only** changes for Workers the user can actually access:

### 1. Accessibility Resolution Pipeline (`AxAiCapabilityUpdateService.resolveAccessibleWorkerProfileIds`)
```text
Available Worker Profiles
  ├── User Workspace Workers (e.g., local ChatGPT Worker)
  ├── Shared Project Workstreams (e.g., project workstream with Gemini Worker lead/config)
  └── Project Settings Worker Grants (e.g., sharedWorkers / workerGrants)
        ↓
AI Capability Updates Catalog
        ↓
Strict Accessibility Filter
        ↓
Home Surface
```

### 2. Strict Filtering Guarantees
- **No Irrelevant Provider News:** If the user has ChatGPT only, Gemini/Claude updates are strictly omitted.
- **Shared Access Inclusion:** If a collaborator gains access to a Worker profile through a shared Project Workstream or grant, relevant updates for that Worker automatically become visible on Home.
- **Zero-State Omission:** If the user has zero accessible workers or no updates match their accessible workers, the AI updates section collapses completely (`const SizedBox.shrink()`) without placeholder clutter.

---

## Separation of Model Discovery from Editorial Updates (Phase 18)

Not every capability change requires a human-authored news article. Conclave distinguishes:
1. **System-Generated Discovery Updates (`AxAiCapabilityUpdateSource.systemGenerated`):**
   - Automatically synthesized when Tool Profile or provider model discovery detects newly available or retired models (e.g. `[A, B] -> [A, B, C]`).
   - Title: `New model available` / `Model retired`.
   - Summary: `Model <modelId> is now available for your <WorkerName>.`
2. **Editorial Updates (`AxAiCapabilityUpdateSource.editorial`):**
   - Curated announcements for major AI releases with customized descriptions, guidance, and deep-link actions.

### Precedence & Merging (`AxAiCapabilityUpdateService.mergeUpdates`)
- When both curated editorial updates and automated model discovery items exist for the same `workerProfileId:modelId` pair, the **curated editorial announcement takes precedence** to avoid redundant noise.
- Both types are formatted and presented uniformly within the "AI updates" surface.

---

## Ephemeral "Running now" Execution Surface (Phase 19)

Home avoids permanent or static "Active Runs" cards that clutter the screen when no work is executing.

### 1. Ephemeral Display Contract
- **Active Execution Only:** The "Running now" section appears **only** when an execution is genuinely active (`run != null && run.isRunning` where status is `RunStatus.running` or `RunStatus.active`).
- **Rich Card Presentation (`_RunningNowCard`):**
  - **Objective:** Prominent title (e.g., `Landing page review`).
  - **Worker & Model Metadata:** Concise context badge (e.g., `ChatGPT · Model X · High`).
  - **Workstream Hierarchy:** Navigation path (e.g., `Website / Landing Page`).
  - **Duration & Progress:** Active execution time or task counts (e.g., `Running for 1m 42s` or `2/5 tasks completed`).
  - **Direct CTA:** `Open →` button navigating directly into the executing Workstream/Run view.
- **Zero-State Omission:** When nothing is running (`run == null` or run has reached a terminal/non-running state like `completed`, `failed`, `cancelled`), the section is completely omitted (`const SizedBox.shrink()`), preventing empty-state clutter.

---

## Conditional Home Composition & Dynamic User Tailoring (Phase 20)

Established Home composition is completely dynamic and modular, evaluating conditions for each section independently:

```text
Established Home
├── if attentionItems:    -> For You
├── if activeExecutions:  -> Running Now
├── if recentWork:        -> Continue Working
├── if productUpdates:    -> What's New
└── if aiUpdates:         -> AI Updates
```

---

## Visual Hierarchy & Attention Emphasis (Phase 21)

Established Home establishes a strict visual hierarchy where actionable and operational signals take precedence over secondary discovery and changelog content:

```text
Home Hierarchy Order
├── 1. For You          [Strongest]  (Approvals, Failures, Invitations, Offline issues)
├── 2. Running Now      [Dynamic]    (Active executions with live telemetry)
├── 3. Continue Working [Primary]    (Daily workstreams and ranked recent activities)
├── 4. What's New       [Secondary]  (Subdued product releases & changelog)
└── 5. AI Updates       [Secondary]  (Subdued model availability & capability changes)
```

### 1. Hierarchy Rules & Visual Weight Guarantees
- **Action Signals First:** Product news and AI model changes must never visually compete with, overshadow, or distract from an approval request, execution failure, workspace disconnection, or project invitation.
- **For You Section Prominence:**
  - Placed at the very top of Home above all executions and workstreams.
  - Distinct high-contrast card border and surface styling.
  - High-visibility semantic category badges (orange for approvals/input, red for execution failures, amber for offline workspaces/workers, primary for invitations).
  - Primary call-to-action buttons (`FilledButton` for primary actions like "Review →" or "Accept") ensure direct operational resolution.
- **Running Now Section:**
  - Positioned immediately below For You when active runs exist, offering real-time visibility and direct jump navigation into active execution trees.
---

## Row-Based Section Flow & Reduced Card Density (Phase 22)

To prevent Home from feeling like a fragmented admin dashboard, Home replaces arbitrary independent card wrappers with clean section row flows:

```text
Section Row Composition
├── For You:        Header -> Row [Item] -> Divider -> Row [Item] ...
├── What's New:     Header -> Row [Update] -> Divider -> Row [Update] ...
└── AI Updates:     Header -> Row [Capability] -> Divider -> Row [Capability] ...

Reserved Card Surfaces
├── Continue Working:   Rich Workstream grid cards (collaboration & snippet context)
├── Running Now:        Highlighted ephemeral execution card (telemetry & live CTA)
└── Onboarding:         Welcome & initial value cards (first-time walkthrough)
```

### 1. Architectural Guidelines
- **Clean Workspace Flow:** `For You`, `What's New`, and `AI Updates` render items as lightweight list rows directly within their section with subtle hairline dividers, eliminating visual clutter from nesting boxes inside boxes.
- **Card Purpose Preservation:** Large cards are reserved strictly for rich content containers where multi-dimensional metadata benefits from a bounded spatial enclosure:
  - **`Continue Working`:** Workstream title, project badge, snippet previews, collaborator identities, and jump actions.
  - **`Running Now`:** High-priority active execution telemetry, objective, elapsed time, and direct workspace navigation.
  - **`Onboarding`:** First-turn welcome cards and setup milestones.

---

## Home Header & Contextual Greeting (Phase 23)

Established-user Home strips away generic marketing subtitles to deliver an uncluttered, distraction-free workspace header:

```text
Established Home Header
├── Title: "Home" (28px Bold)
└── Subtitle (Optional): Contextual greeting (e.g. "Good morning, Vitalii.") or explicit custom greeting
```

### 1. Architectural Rules
- **No Marketing Subtitles:** Legacy marketing taglines like `"Your execution capacity at a glance."` are permanently eliminated. The workspace content underneath speaks for itself.
- **Contextual Greeting:**
  - When `greeting` is explicitly provided, it renders directly beneath `Home`.
  - When `userName` is provided, Home dynamically derives an appropriate time-of-day greeting:
    - Hour `< 12`: `Good morning, <userName>.`
    - Hour `12..17`: `Good afternoon, <userName>.`
    - Hour `18..23`: `Good evening, <userName>.`
  - When neither `greeting` nor `userName` is supplied, `Home` renders cleanly as a standalone title without residual spacing or empty subtitle lines.

---

## Archive Management in Navigation Context & Exclusion from Home (Phase 24)

Home is a focused attention and collaboration hub; it is not a miscellaneous launchpad for administrative utility buttons or secondary shortcuts.

```text
Archive Management Scope
├── Navigation Context (App Menu / Sidebar): "Archived Projects" dialog & restore actions
├── Project Context (Project / Workstream views): "Archive" / "Restore" actions
└── Home: Excluded (Zero utility buttons or archive shortcuts)
```

### 1. Architectural Rules
- **No Archive Buttons on Home:** The legacy `"Archived Projects"` button previously located beneath the title is permanently removed from Home.
- **Dedicated Navigation Placement:** Archive discovery and project restoration live cleanly inside the global application menu (`AppMenu`) and sidebar (`AppSidebar`), or inside the Project management surface (`ProjectPage`), preserving Home purely for active attention, active execution, active workstreams, and relevant updates.

---

## Integrated Invitation UX & Single Source of Truth (Phase 25)

Invitations remain prominent across Conclave AX without maintaining disparate, disconnected invitation models or state pools.

```text
AxProjectInvitation Reactive Stream
               ↓
    AxCollaborationMutations
               │
  ┌────────────┼────────────┬─────────────┬──────────────┐
  ▼            ▼            ▼             ▼              ▼
Home Card   For You     Notification   Sidebar Tree   Project
(New User)  (Attention)    Badge       (Pending)     Membership
```

### 1. Unified State & Immediate Synchronization
- **Single Source of Truth:** `store.invitations` and `store.collaboration` own the canonical state and lifecycle for project invitations across all presentation projections.
- **Projections over the Same State:**
  - **New-User Home:** `Join a Project` priority card.
  - **Established-User Home:** Top-ranked `Project invitation` rows in the `For You` attention section via `AxHomeAttentionProjector`.
  - **Notification Center & Inbox:** `Pending invitations` section within `_showNotifications` dialog.
  - **Sidebar Project Tree:** `Pending invitations (N)` group in `ProjectTree`.
- **Immediate Multi-Surface Updates:**
  - Accepting an invitation from Home executes `store.acceptInvitation(invite)` which optimistically updates both the `invitations` and `projects` stores.
  - Instantly without page reload or manual refetch:
    1. Home removes the invitation item.
    2. Notification badge decreases.
    3. Sidebar `ProjectTree` adds the joined project and clears the pending invitation entry.
    4. Project membership queries are refreshed.
    5. The client transitions directly into the newly joined project conversation space.

---

## Actionable Deep-Link Destinations for Every Home Item (Phase 26)

Home never displays passive information or dead-end cards without an obvious next action. Every item on Home resolves to an exact, concrete destination:

```text
Home Items & Canonical Deep-Link Destinations
├── 1. Project Invitation   → Accept / Decline actions & direct Project entry
├── 2. Needs Input / Review → Exact Workstream conversation context
├── 3. Execution Failure    → Exact Workstream & Run failure inspector
├── 4. Worker/Workspace Prob→ Exact Workspace configuration & reconnection surface
├── 5. Running Now          → Exact active Workstream & live execution view
├── 6. Continue Working     → Exact Workstream conversation
├── 7. What's New           → Update detail dialog & changelog
└── 8. AI Capability Update → Relevant Worker & model configuration
```

### 1. Architectural Rules
- **No Dead-End Content:** If an item exists on Home, it must provide a direct primary action button or interactive target routing to its operational resolution.
- **Context-Preserving Routing:**
  - `onOpenWorkstream(projectId, workstreamId)` is prioritized over broad project landing pages for conversation turns, unresolved input requests, reviews, and recent work.
  - `onOpenWorkspaces()` is directly bound to offline workspaces, worker credential faults, and AI model configurations.
---

## Progressive Loading Strategy & Fault-Isolated Section Rendering (Phase 27)

Home avoids monolithic, all-or-nothing data fetches. Rendering progresses through decoupled layers while strictly isolating potential failures:

```text
Progressive Rendering Flow
├── 1. Cached Home (Immediate render from in-memory reactive stores)
├── 2. Attention Refresh (Background sync for invitations, approvals, faults)
├── 3. Recent Work Refresh (Background sync for active conversation workstreams)
└── 4. Updates Refresh (Changelog & AI model capability background fetches)
```

### 1. Architectural Guarantees & Fault Isolation
- **Non-Blocking Execution:** Home never stalls rendering while awaiting secondary or background service payloads.
- **Strict Section Fault Isolation:**
  - An error, timeout, or schema failure in the **What's New** product updates service will **never** prevent `For You`, `Running Now`, or `Continue Working` from rendering.
  - An error or empty response in the **AI Updates** capability service will **never** produce a whole-page error or crash the application.
  - If a secondary section's data projection throws an exception, it is caught locally and gracefully collapses to `const SizedBox.shrink()`, preserving primary triage and daily workflows intact.
---

## Offline & Degraded Connectivity Behavior (Phase 28)

When network connectivity is disrupted or AX cannot reach Cloud services, Home preserves user workflow continuity instead of blanking out or rendering full-page error blocks:

```text
Offline Home State
├── Small Connectivity Indicator (Header: "Offline · Cached data")
├── Cached Continue Working (Full read and local conversation resumption)
├── Cached What's New & AI Updates (Full read of locally stored announcements)
└── Server-Dependent Actions (Gracefully degraded/disabled without disrupting read access)
```

---

## Notifications Cleanup & Normalized Domain Terminology (Phase 29)

Home and the Notification Center utilize a normalized domain model structured strictly around the five fundamental Conclave entities:

```text
Normalized Notification Domain
├── 1. Workstream   (workstreamNeedsInput, workstreamCompleted, workstreamFailed)
├── 2. Workflow Run (workflowRunCompleted, workflowRunFailed, workflowRunNeedsApproval)
├── 3. Worker       (workerCredentialProblem, workerInstallFailed)
├── 4. Workspace    (workspaceOffline)
└── 5. Project      (projectInvitationReceived)
```

### 1. Architectural Rules & Normalization
- **No Ambiguous "Run" Assumptions:** Notifications distinguish between ongoing Workstream conversational turns and background Workflow Run executions.
- **Accurate Navigation Target Resolution:**
  - `AxNotificationTarget.workstream` → Deep-links directly to `AxNavigation.workstream(projectId, workstreamId)`.
  - `AxNotificationTarget.workflowRun` → Deep-links directly to `AxNavigation.run(projectId, runId)`.
  - `AxNotificationTarget.workspace` / `workspaces` → Deep-links to `AxNavigation.workspaces(workspaceId: ...)`.
  - `AxNotificationTarget.project` → Deep-links to `AxNavigation.project(projectId)`.
- **Actionability & Priority Mapping:**
  - High priority: `workstreamNeedsInput`, `workstreamFailed`, `workflowRunNeedsApproval`, `workflowRunFailed`, `workerCredentialProblem`.
  - Normal priority: `workspaceOffline`, `workerInstallFailed`, `projectInvitationReceived`.
  - Low priority: `workstreamCompleted`, `workflowRunCompleted`.
- **Home Triage Alignment:** `AxHomeAttentionProjector` maps normalized notification events cleanly into `AxHomeAttentionItem` triage rows with semantic action CTAs (`Review →`, `Inspect →`, `Fix →`, `Connect →`, `Open →`, `View →`).

