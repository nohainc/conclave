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
- **Purpose:** Triage actionable items that block progress, require decisions, or demand attention.
- **Max Items:** 3–5 highest-priority items on Home (full history remains in the dedicated Notification Center).
- **Semantics Included:**
  - Project invitations (with direct `Accept` / `Decline` actions)
  - Workstream input/decision requests (e.g., questions posed to the user)
  - Completed worker reviews or task outcomes ready for human inspection
  - Worker/credential attention warnings (e.g., sign-in required, missing API keys)
  - Workspace connectivity interruptions
- **Absence Behavior:** If nothing requires attention, the section omits empty filler text (`"Nothing needs your attention"`) to preserve a clean, focused surface.

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
    ├── isNewUser == true  (projects.isEmpty && invitations.isEmpty)
    │     └── NewUserHome
    │
    └── isNewUser == false (projects.isNotEmpty || invitations.isNotEmpty)
          └── EstablishedUserHome
```

### 1. NewUserHome
- **Condition:** Active *only* when the user has `projects.isEmpty && invitations.isEmpty`.
- **Experience:**
  - Dedicated welcome header explaining Conclave AX as a collaborative AI workspace.
  - Actionable **Get started** card with two clear pathways:
    1. `Create a Project`: Start a shared project and collaborate.
    2. `Connect AI / Workspace`: Advanced pairing of local workspace and CLI workers.
  - **How Conclave AX works** highlights: People first, Private credentials, and Shared conversations.
  - Completely omits dashboard sections (`For you`, `Continue working`, `What's new in Conclave`, `AI updates`) to avoid blank/confusing dashboard states.

### 2. EstablishedUserHome
- **Condition:** Active when the user has either `projects.isNotEmpty` OR `invitations.isNotEmpty`.
- **Key Invariant:** A user with 0 projects but pending invitations is **not** a new user; they have an active collaboration context awaiting decision.
- **Experience:**
  - **For You**: Prioritizes pending invitations with direct `Accept` / `Decline` controls, as well as workstream attention items and findings.
  - **Running Now**: Conditionally visible when active runs exist.
  - **Continue Working**: Contextual workstreams (omitted if no projects exist).
  - **What's New in Conclave**: Official product updates.
  - **AI Updates**: Scoped AI capability news for available worker types.
  - Strictly omits onboarding cards and getting-started tutorials.
