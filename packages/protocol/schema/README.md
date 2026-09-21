# Conclave protocol schemas

This directory is the canonical, language-neutral contract source for messages crossing the Cloud, Agent Engine, and Worker Plugin boundaries.

Protocol versions use `major.minor.patch`:

- a different major is incompatible and must be rejected during handshake;
- a higher minor may add optional fields and remains readable by older peers;
- patch changes do not alter the contract.

The Zod schemas in `src/index.ts` are the TypeScript runtime validators for the domain payloads. Dart bindings in `packages/dart/protocol` validate the same envelope and the shared Task messages at the native boundary.
