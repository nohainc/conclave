# Worker Registry

Workers are configurable resources, not provider aliases. A Worker resource declares its type, provider metadata, adapter version, capabilities, roles, permissions, availability, cost metadata, and execution environment.

Core resolves a requirement such as `code_review` by filtering the registry for:

1. `available` workers;
2. the requested capability;
3. optional role, permission, and execution-environment constraints;
4. optional maximum estimated cost;
5. the lowest configured estimated attempt cost, then stable ID order.

Provider names are never interpreted as roles. A worker from any provider may be configured as a reviewer, lead, implementer, or another role, and a provider may have multiple workers with different capabilities.

The initial in-memory registry implements the Core routing behavior. The D1 worker row is extended by migration `0002_worker_registry.sql`; a persistence adapter can populate the same `WorkerResource` shape without changing resolution logic.
