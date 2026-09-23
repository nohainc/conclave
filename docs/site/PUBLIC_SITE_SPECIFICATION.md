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

| Domain | Responsibility | Authentication |
| --- | --- | --- |
| `conclaveax.com` | Public Astro/static-first website | None required |
| `www.conclaveax.com` | Redirect to `https://conclaveax.com` | None required |
| `app.conclaveax.com` | Authenticated Conclave AX Flutter Web application | Better Auth |

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
- links to Conclave AX must remain ordinary HTTPS links and work without shared
  client state.

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

