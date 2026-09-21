# Worker Registry

Workers are configurable resources, not provider aliases. A Worker resource declares its stable identity, type, capabilities, roles, permissions, independence attributes, and availability. Provider, transport, authentication, billing, adapter version, and execution environment are declared by separate Connection resources.

Core resolves a requirement such as `code_review` to a Worker/Connection binding by filtering the registry for:

1. available workers and connections;
2. the requested worker capability;
3. optional role and permission constraints;
4. optional connection execution-environment constraints;
5. optional maximum connection cost;
6. the lowest configured connection attempt cost, then stable Worker and Connection IDs.

Provider names are never interpreted as roles. A worker from any provider may be configured as a reviewer, lead, implementer, or another role, and a provider may have multiple workers with different capabilities.

The initial in-memory registry implements the Core routing behavior. Worker-to-connection bindings are persisted in `worker_connections`, and Connection resources in `connections` via migration `0011_worker_connections.sql`. Persistence adapters must load both resources without re-embedding connection data into `WorkerResource`.
