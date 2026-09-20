# Conclave Local Runtime

The Local Runtime is the outbound desktop/runtime boundary for repository work. Cloud never opens an inbound port on the user's machine. The runtime establishes an outbound transport, receives an approved operation envelope, performs the operation inside a registered repository root, and sends back immutable structured evidence.

## Supported operations

- `read_file` — bounded UTF-8 file reads;
- `search` — bounded recursive text search, excluding `.git`, `node_modules`, and `.dart_tool`;
- `write_file` — bounded writes with an optional expected content digest;
- `git` — `status`, `diff`, and current `branch`;
- `shell` — explicitly allowlisted executable/argument execution;
- `check` and `build` — separately allowlisted command classes for tests and builds.

Commands are passed as argument arrays and spawned with `shell: false`. The runtime never evaluates a command string through a shell. The policy controls which executable may run for each command class, the working directory is repository-root confined, and operation/request limits are enforced locally.

## Approval and evidence

Every request contains a request ID, repository ID, operation kind, and expiring approval. The approval must explicitly include the requested operation kind. A request outside the registered root, past its approval expiry, or outside the command allowlist is rejected and still returns evidence with the rejection reason.

Evidence includes the request and repository IDs, operation, status, summary, bounded output, SHA-256 content digest, exit code, command arguments when applicable, timestamps, duration, approval ID, and the resolved repository root. This is the evidence Core can attach to an Attempt, Artifact, Verification, or Event.

## Transport boundary

`OutboundRuntimeSession` depends on a small `RuntimeTransport` interface. The current package does not prescribe WebSocket, long polling, or a desktop connector. A production adapter must authenticate the outbound connection, preserve request IDs for idempotency, reconnect safely, and never accept unauthenticated arbitrary operations. The transport carries commands and evidence; it does not bypass runtime policy.

## Safety limits

The runtime has bounded read/write/search sizes and command timeouts. Repository paths are resolved relative to a registered absolute root; absolute request paths and `..` escapes are rejected. Credentials are not part of runtime requests or evidence. Future coding-agent adapters must use the same operation and approval boundary rather than receiving unrestricted shell access.
