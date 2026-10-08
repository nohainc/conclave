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



