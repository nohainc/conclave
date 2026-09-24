# V6-28 release gate

Run `npm run v6:release-gate` from the repository root. It verifies:

- TypeScript build;
- solo, team concurrency, schema, scheduler, and recovery acceptance;
- generated protocol consistency;
- V6 architecture and convergence search gates;
- Markdown documentation links;
- Cloudflare production preflight;
- Flutter Studio UI acceptance;
- macOS Workspace runtime acceptance.

The Windows and Linux compile matrix is an external CI requirement. Strict CI
jobs must set `V6_REQUIRE_PLATFORM_MATRIX=1` and `V6_PLATFORM_MATRIX=passed`
only after those builds complete.

The final product scenario is four people discussing one feature, explicitly
asking AI to work on it, safely iterating from a checkpoint, and running other
features in parallel without sharing mutable checkout state.
