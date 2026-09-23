# Conclave AX Landing-Page Release Gate

The public site becomes the public entry point only when the generated release
passes the automated gates and a human unfamiliar with Conclave AX passes the
comprehension review below.

## Automated gate

From the repository root:

```bash
pnpm site:build
pnpm site:release
pnpm site:content
pnpm site:accessibility
pnpm site:responsive
pnpm site:performance
pnpm site:security
pnpm site:analytics
pnpm site:test
```

The release gate verifies the required routes and assets, homepage sections,
direct `app.conclaveax.com` CTAs, privacy/terms/security links, no public
Studio/Plugin/Agent terminology, and the `www` redirect contract. The other
checks cover SEO metadata, social preview assets, accessibility, responsive
behavior, performance budgets, security headers, analytics privacy, and route
tests.

## Human comprehension review

Ask someone who has not worked on Conclave AX to open `conclaveax.com` without
additional explanation. Within 30–60 seconds, they should be able to answer:

1. What does Conclave AX do?
2. Why can multiple Workers improve the result?
3. Why is a Conclave Host needed?
4. Which action starts the product?

They should identify **Open Conclave AX** without being directed, understand
that Accounts are external AI identities, and not confuse a Host with an AI
model or the public site with the authenticated application.

## Required content checklist

- `conclaveax.com` serves the public website.
- `www.conclaveax.com` redirects to the canonical domain.
- Homepage CTA opens `app.conclaveax.com`.
- Hero, product explanation, workflow, Hosts, Workers, Accounts/privacy,
  quality/verification, security/architecture, and final CTA are present.
- SEO metadata, social preview, responsive layout, accessibility, performance,
  security headers, custom 404, privacy, and terms are present.
- No legacy product terminology, old architecture diagram, or unsupported
  product promise appears in generated public HTML.
