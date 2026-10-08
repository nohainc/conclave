# Conclave AX Public Site Release Gate

The public site is ready to serve as the public entry point when automated
checks pass and a person unfamiliar with Conclave AX can explain the product
from the page without additional context.

## Automated checks

From the repository root, run the site checks defined by `package.json`:

```sh
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

The checks cover generated routes and assets, metadata, application links,
accessibility structure, responsive behavior, security headers, analytics
privacy, and performance budgets. Confirm `www.conclaveax.com` redirects to
`https://conclaveax.com` and the primary action opens
`https://app.conclaveax.com`.

## Human review

Ask someone who has not worked on Conclave AX to review the site without
additional explanation. They should be able to answer:

1. What does Conclave AX help people do?
2. How do Spaces and Threads use Conclave Workspace?
3. Where does provider CLI execution happen?
4. How do they open the application?

They should understand that execution runs through a local Workspace and that
provider credentials stay with provider CLI software on the user's machine.

## Content checklist

- The public site and authenticated application have clear, separate roles.
- Product explanation matches the current Space, Thread, Workspace,
  Worker, Engine, and Tool Profile architecture.
- Security and provider claims are supported by current implementation.
- Privacy and Terms routes are present and current.
- No retired product concepts or unsupported capabilities appear in generated
  public HTML.
- Keyboard navigation, narrow layouts, zoom, reduced motion, and contrast
  preferences remain usable.
