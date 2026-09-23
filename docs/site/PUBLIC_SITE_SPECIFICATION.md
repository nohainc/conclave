# Conclave AX Public Website Specification

Status: SITE-0 contract  
Canonical public domain: `https://conclaveax.com`

## Purpose

The website is the public presentation layer for Conclave AX. It explains the
product, establishes credibility, communicates the Host + Worker architecture,
and sends visitors to the authenticated application.

It is a small product of its own, deliberately simpler than Conclave AX. It is
not a second application frontend and does not own user, Workspace, Project,
Chat, Run, Host, Worker, or Account state.

## Domain contract

| Domain               | Responsibility                                    | Authentication |
| -------------------- | ------------------------------------------------- | -------------- |
| `conclaveax.com`     | Public Astro/static-first website                 | None required  |
| `www.conclaveax.com` | Redirect to `https://conclaveax.com`              | None required  |
| `app.conclaveax.com` | Authenticated Conclave AX Flutter Web application | Better Auth    |

The website must never proxy or embed the authenticated application. Links into
the product use `https://app.conclaveax.com` and may include a safe route for
the intended destination.

Conclave Cloud is the API, authentication, and orchestration control plane. The
Conclave Host is downloaded and paired from inside Conclave AX; the public
website does not perform Host enrollment or distribute machine credentials.

## Primary visitor outcomes

The initial release should help a visitor answer four questions quickly:

1. What is Conclave AX?
2. How do Cloud, Host, Workers, and Accounts fit together?
3. Why should I trust it with my work and external AI accounts?
4. Where do I start?

The primary call to action is **Open Conclave AX**, linking to
`https://app.conclaveax.com`.

The secondary call to action is **See how it works**, linking to the site's
architecture/how-it-works section or page. It must remain a public explanatory
route and must not require authentication.

## Initial navigation

The first release has only this navigation:

- Product
- How it works
- Workers
- Security
- Open Conclave AX

Navigation should remain shallow and readable. Pricing, blog, and a separate
documentation portal are explicitly out of scope for the initial release.

The footer provides only live destinations: Product, How it works, Security,
the public GitHub repository, Privacy, and Terms. The initial legal routes are
`/privacy/` and `/terms/`; they may begin as concise architecture-aware notices
but must be replaced with final service notices before public account creation.

## Content contract

### Product

Explain Conclave AX as a workspace for directing AI and tool work with visible
execution, evidence, and control. Keep the promise concrete; do not imply that
Conclave guarantees model correctness.

### How it works

Show the public architecture in this order:

```text
Conclave AX -> Conclave Cloud -> Conclave Host -> Worker
                                      |
                                   Account
```

Use plain language:

- Conclave AX is where people ask, review, and inspect work.
- Conclave Cloud authenticates users, authorizes Workspaces, and orchestrates.
- Conclave Host provides an enrolled machine and supervises local execution.
- Workers are installable AI/tool integrations.
- Accounts identify the external AI identity used for an execution.

### Workers

Present Workers as capability integrations, not as separate products or
configured machine identities. The section may describe representative Worker
categories and capabilities, but it must not promise availability, providers,
models, pricing, or operating-system support that the current catalog does not
actually provide.

### Security

Explain the boundaries that matter to a public visitor:

- human login uses Conclave AX and Better Auth;
- Host identity is separate from human identity;
- Accounts are private by default and may be explicitly shared;
- raw Account secrets remain in Host secure storage and are not public content;
- Workers do not connect directly to Conclave Cloud;
- Cloud remains authoritative for Workspace authorization and execution state.

Security copy must describe protections accurately and avoid absolute claims
such as “unhackable,” “zero risk,” or guaranteed model correctness.

## Public terminology

Use these names consistently:

- **Conclave AX** — the authenticated web application;
- **Conclave Host** — the desktop application installed on a machine;
- **Worker** — an installable AI/tool integration;
- **Account** — the user-facing name for an external AI identity;
- **Workspace** — a shared area for people and work.

The following terms are banned from public copy and navigation:

- Studio;
- Agent;
- Plugin;
- Credential Profile.

“Credential Profile” remains an internal Cloud/domain term only. Provider names
may appear when describing supported Workers, subject to the actual catalog and
trademark requirements.

## Explicit non-goals

The website must not:

- implement login, Workspace switching, Chat, Runs, or orchestration;
- show private Workspace, Host, Worker installation, or Account data;
- host a second copy of Conclave AX's Flutter application;
- install or pair a Host directly;
- collect API keys, OAuth secrets, or machine credentials;
- expose an authenticated Cloud API as a public website concern;
- require pricing, blog, or docs sections for the initial release.

## Implementation constraints

- Astro with static-first output;
- minimal client-side JavaScript, added only for clear navigation or accessible
  interaction;
- responsive layouts for narrow, medium, and wide screens;
- keyboard-accessible navigation and visible focus states;
- semantic headings, landmarks, links, and buttons;
- no hover-only content or critical interaction;
- canonical metadata and a redirect from `www` to the apex domain;
- OpenGraph/Twitter metadata, a branded social preview, `sitemap.xml`,
  `robots.txt`, favicon, and a web manifest;
- links to Conclave AX must remain ordinary HTTPS links and work without shared
  client state.

The public site is performance-budgeted for static HTML, no third-party
JavaScript, system fonts, and small generated assets. CI checks built HTML,
CSS, and script sizes and rejects external script sources. Production workers
cache fingerprinted assets immutably; HTML remains revalidated.

Generated pages also pass an accessibility gate for document landmarks, one
logical `h1`, heading order, viewport zoom, image alternatives, button types,
and keyboard-safe tabindex values. Architecture diagrams retain visible text
labels in addition to visual connectors. Manual release review must traverse
the header, mobile menu, links, buttons, and footer by keyboard at narrow and
zoomed layouts.

Responsive review covers 320px, 375px, 430px, 768px, 1024px, and wide desktop
layouts. At the 800px breakpoint, navigation becomes a drawer, diagrams and
comparison grids become vertical or single-column, and primary actions retain
comfortable tap targets.

## Marketing analytics contract

Marketing analytics are separate from Conclave Cloud application telemetry.
The site may send only these aggregate event names: `landing.page_view`,
`cta.open_app`, `navigation.how_it_works`, `section.host_reached`, and
`section.workers_reached`. Payloads contain only the event name, public path,
and event timestamp. The endpoint is opt-in through
`PUBLIC_SITE_ANALYTICS_ENDPOINT`; when it is unset, the site sends no analytics
requests. The site does not use cookies, user IDs, Workspace IDs, credentials,
Chat content, Account data, or application events.

The public Worker sends a self-only Content Security Policy, denies framing,
sets strict transport/referrer/permissions policies, and strips `Set-Cookie`
from asset responses. The marketing site’s analytics endpoint must be
same-origin; the authenticated app owns its own cookie scope and application
security boundary.

## Visual system contract

The site uses one restrained, technical visual theme: warm paper surfaces, ink
text, muted lavender accent color, crisp borders, and compact monospace details.
It does not depend on decorative gradients, robot imagery, glowing orbs, or
animation to communicate the architecture.

Design tokens live in `apps/site/src/styles/tokens.css`. Reusable Astro
primitives live in `apps/site/src/components/` and include layout containers,
sections, buttons, badges, cards, section headers, architecture nodes, terminal
panels, navigation, and footer. New sections should compose these primitives
before adding page-specific CSS.

## Regression and anti-drift constraints

CI checks the generated critical routes for required content, metadata, direct
Conclave AX CTA targets, navigation anchors, accessibility structure, security
boundaries, responsive rules, and the existing performance budgets. Keep these
constraints when using AI-assisted implementation:

- Do not add a new visual system per section.
- Do not introduce a frontend framework for one widget.
- Do not add JavaScript when semantic HTML and CSS are sufficient.
- Do not invent unsupported product capabilities or Workers.
- Prefer existing components and design tokens over one-off markup and styles.
- Keep important architecture and product claims visible in generated HTML.

The current regression gate is intentionally static and dependency-light. It
does not replace a manual browser review at release time; future screenshot
coverage may be added when a stable browser capture environment is available.
Production claims are tracked and reviewed in
`docs/site/PUBLIC_SITE_CONTENT_AUDIT.md`; unsupported architecture targets must
not be presented as current capabilities.

The system supports wide, medium, and narrow layouts; visible keyboard focus;
reduced-motion preferences; and forced-colors/high-contrast mode. Motion is
limited to short state transitions and must not carry essential meaning.

The public site, Conclave AX, and Conclave Host share the same recognizable
brand foundation: the C mark, Conclave AX purple accent, warm neutral surfaces,
ink text, restrained borders, and the product terms Conclave AX, Host, Worker,
Account, Workspace, Project, Chat, and Run. The application and Host may use
denser layouts and darker navigation for productivity, but their entry screens,
titles, buttons, and marks should make the transition from the website feel
intentional. Public-site navigation never duplicates application login logic.

Cross-product navigation is deliberately shallow: the website's primary
**Open Conclave AX** links directly to `https://app.conclaveax.com`; the
authenticated application may link back to the website or an About surface.
Host download and pairing remain inside Conclave AX under Hosts, so the public
site never handles signed downloads, enrollment tokens, or authentication
state.

## Acceptance checklist

An implementation is conformant when a visitor can, without signing in:

- identify the website as the public Conclave AX presentation layer;
- distinguish it from the authenticated app at `app.conclaveax.com`;
- explain the Cloud -> Host -> Worker execution path;
- understand that Accounts are external AI identities, not Host software;
- find **Open Conclave AX** and **See how it works**;
- find the Product, How it works, Workers, and Security navigation items;
- find no Studio, Agent, Plugin, or Credential Profile in public copy;
- use the site on keyboard and narrow screens.
