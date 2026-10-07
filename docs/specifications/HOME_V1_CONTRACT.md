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

### 1. For You
- **Purpose:** Triage actionable items that block progress, require decisions, or demand attention across all projects.
- **Max Items:** 3–5 highest-priority items projected on Home (full triage and history remain in the dedicated Notification Center via the `View all` link).
- **Priority Hierarchy (Top to Bottom):**
  1. **Project invitation requiring decision** (`AxAttentionKind.invitation`) — with direct `Decline` / `Accept` actions.
  2. **Approval / input required** (`AxAttentionKind.needsInput`) — e.g. question/decision needed in a workstream, findings requiring review.
  3. **Failed execution** (`AxAttentionKind.failedExecution`) — run or task failures requiring triage or rerun.
  4. **Worker / account problems** (`AxAttentionKind.workerProblem`) — e.g. expired credentials, authentication errors.
  5. **Workspace connectivity problems** (`AxAttentionKind.workspaceProblem`) — e.g. local workspace offline.
  6. **Completed work worth reviewing** (`AxAttentionKind.completed`) — e.g. AI worker finished review or artifact.
  7. **General info / other** (`AxAttentionKind.finding`, `AxAttentionKind.general`).
- **Card Structure:**
  - Semantic category chip (e.g. `Project invitation`, `Needs your input`, `Failed execution`, `Worker needs attention`, `Workspace offline`, `Completed`).
  - Relative timestamp (e.g. `8 minutes ago`, `24 min ago`).
  - Item Title and contextual Subtitle (e.g. `Julia invited you to "Family Travel"`, `Owner · 8 minutes ago`).
  - Contextual action buttons (`Decline` / `Accept`, `Review →`, `Open →`, `Inspect →`, `Fix →`, `Connect →`).
- **Absence Behavior:** If nothing requires attention, the section renders nothing (omits empty filler text like `"Nothing needs your attention"`) to preserve a clean, focused surface.

### 2. Continue Working
- **Purpose:** Fast resumption of ongoing collaborative work in context.
- **Content:** Replaces raw project list with active Workstreams:
  - Project Name + Workstream Title
  - Active Collaborators & AI Worker involved (e.g., *"You and ChatGPT"*, *"Julia and Gemini"*)
  - Last activity snippet / decision summary
  - Relative timestamp
  - Direct `Continue →` action navigating straight into the Workstream conversation
- **Absence Behavior:** Omitted if no recent workstream history exists.

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
