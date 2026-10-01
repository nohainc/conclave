# Worker release manifest contracts

> **Migration-only contract:** Worker Release Manifest v2 describes the
> superseded per-provider native Worker release path. Architecture v8 uses one
> generic CLI Worker Engine and signed Tool Profile Releases. Keep this
> manifest for migration evidence until v8 acceptance and cleanup; do not use it
> for new v8 Workers or releases.

Historical standalone Dart Worker releases used
`WorkerReleaseManifestV2Schema` and `WorkerReleaseManifestV2` from
`src/worker-release-v2.ts`. The native release
manifest is provider-neutral and declares Worker identity/version, platform,
Local Worker Protocol range, state schema range, capabilities, Workspace
permissions, executable-relative path, release channel, package and archive
digests, and publisher signature metadata.

The manifest is a signed sidecar to the `.tar.gz` artifact. The archive hash
covers the exact compressed bytes. The package digest covers sorted extracted
file paths, permission modes, and file contents. The signature covers the
canonical JSON of every manifest field except `signature`, with the domain
prefix `conclave-worker-release-manifest-v2`. Detached metadata avoids a
signature/hash cycle.

The v2 schema rejects unknown fields, including provider executable
prerequisites, provider version/auth commands, and provider CLI environment
policy. Those details were implemented inside each native Worker executable;
in v8 they belong in the constrained Tool Profile schema when representable.

## Legacy V6/V7 adapter manifests (migration history)

The following schemas and package assets describe the unreleased Node-era
migration path. They remain as historical source material; do not use them for
new v8 implementations.

The package still exports the v6 package contract and the V7 adapter contract.
Legacy V7 consumers use `V7AdapterManifestSchema` and
`V7AdapterMessageSchema`; v6 callers remain on `WorkerManifestSchema` during
that migration.

### V7 adapter manifest

`workerTypeId` identifies an integration. Models belong in Worker or
Assignment configuration. Manifests declare adapter version, protocol version,
publisher, platform support, capabilities, permissions, auth strategies, model
selection behavior, package-owned prerequisites, signed environment policy,
executable, arguments, secret requirements, health check, package digest,
signature, and release channel.

The adapter executable must be a normalized package-relative path. Workspace
validates package-owned prerequisite declarations but does not discover or
launch provider tools; each package implements its own prerequisite checks.
`environmentPolicy.environmentPassthrough` names the ambient variables the
Workspace may copy into the package process. The generic launcher starts with
`includeParentEnvironment: false`, applies its bounded base environment, and
copies only signed policy names. `environmentPolicy.providerCliPassthrough`
is consumed by the package when constructing a provider CLI's environment;
Workspace does not interpret those provider-specific names. For example, the
Antigravity package declares Gemini API keys, custom Gemini/Vertex endpoints,
and configured ADC variables for forwarding to `agy`, while XDG and
Cloud-SDK configuration paths support local auth/config discovery. Keychain
sign-in remains local to Antigravity and does not require Workspace credential
handling.
`sensitivePassthrough` identifies values to redact from package output. The
legacy `environmentRequirements` field remains accepted for already-published
packages. The runtime also verifies package signature/digest and resolves
executable symlinks within the verified package root before launch.

The Codex and Antigravity packages share `adapters/shared/cli_tool_runner.mjs`.
The release packager includes it as `lib/cli_tool_runner.mjs` in each package.
It owns executable lookup, bounded command and JSONL stream execution, filtered
environment construction, deadlines, stderr capture, cancellation, and process
tree cleanup. Each provider adapter keeps its own executable setting, required
environment names, command arguments, readiness checks, and event parsing.
The CLI packages cache their last executable path under the user's local cache
directory, validate it before reuse, and search PATH and package-declared known
install directories when needed. Readiness probes report the CLI version
through `probe.result`.

First-party packages use Local Worker Protocol 2.4. `passive` performs
discovery, version checks, and any cheap authentication checks the CLI supports
without a model request. `live` performs a small `OK` request. Results
include structured `checks[]` with stable issue codes and optional diagnostics
bounded to 2,048 characters. Workspace keeps those diagnostics local; they are
not included in Cloud inventory. Protocol 2.1 and 2.2 retain their legacy
probe-result shape; protocol 2.3 remains supported without a deadline field
during migration. Protocol 2.4 execute requests carry the remaining assignment
timeout; packages derive their CLI deadline from it and
reserve a short cleanup grace. Live readiness probes use a separate 30-second
deadline.

The Host V7 package store installs a pre-extracted directory or a bounded
gzip-compressed tar archive. Its package digest is SHA-256 over files sorted by
normalized relative path, excluding only the root `manifest.json`; each entry
hashes `path`, a zero byte, file contents, and a zero byte. The V7 signature
authenticates both that digest and the canonical JSON of every manifest field
except `signature`:

~~~text
digest + newline + canonical-json(manifest-without-signature)
~~~

This binds executable, permissions, platform, authentication, secret
requirements, and environment policy to the package signature. Signing only the file tree would leave
those security declarations mutable. Symlinks are rejected, archive entries
are extracted into private staging, and digest, signature, and catalog manifest
are checked before immutable activation. The declared protocol or process-exit
health check must pass before the active pointer changes; rollback repeats
digest, signature, path, and health checks. The Host repeats package admission
when resolving a Worker for every assignment. Cloud stores immutable release
metadata and archives. Add Worker acquires the latest supported release,
checks the archive hash and exact manifest binding, then uses the same package
admission path. Background update and revocation reconciliation remain future
work.

Secret requirements name environment variables that the Workspace may expose
to the Worker Package process. The package's signed environment policy
separately controls which values it may forward to its provider CLI. The
protocol itself has no credential-value field and no
working-directory field. Workspace resolves and sets the Workstream CWD at
process launch. The production resolver reads credential values from the OS
secure store, maps only matching declared requirements, and redacts returned
progress, errors, output, and artifacts.

## V7 process protocol

Frames are strict JSON objects exchanged over structured stdin/stdout and are
limited to 1 MiB. Supported message types include initialize, validate,
execute, progress, result, error, health, and version. Unknown fields and
unknown message types are rejected. Cancellation initially uses child-process
supervision and termination, not a provider-supplied path or shell command.


Cloud's V7 catalog supports immutable owner-published releases, channel/platform
filtering, publisher-scoped revocation, and archive download. The Workspace
checks catalog metadata against the downloaded manifest before package-store
admission; signature, permissions, platform, and health are independently
verified locally.
