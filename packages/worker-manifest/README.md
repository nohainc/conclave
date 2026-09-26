# Worker adapter contracts

The package exports the v6 package contract and the additive Architecture v7
adapter contract. V7 consumers should use `V7AdapterManifestSchema` and the
`V7AdapterMessageSchema` framed protocol; v6 callers remain on
`WorkerManifestSchema` during the migration.

## V7 adapter manifest

`workerTypeId` identifies an integration. Models belong in Worker or
Assignment configuration. Manifests declare adapter version, protocol version,
publisher, platform support, capabilities, permissions, auth strategies, model
selection behavior, prerequisites, executable, arguments, secret requirements,
health check, package digest, signature, and release channel.

The adapter executable must be a normalized package-relative path. Prerequisite
executables must be command names resolved under Workspace policy; manifests
cannot provide arbitrary executable paths. The runtime must still verify package
signature/digest and resolve executable symlinks within the verified package
root before launch.

The Host V7 package store installs a pre-extracted directory or a bounded
gzip-compressed tar archive. Its package digest is SHA-256 over files sorted by
normalized relative path, excluding only the root `manifest.json`; each entry
hashes `path`, a zero byte, file contents, and a zero byte. The V7 signature
authenticates both that digest and the canonical JSON of every manifest field
except `signature`:

~~~text
digest + newline + canonical-json(manifest-without-signature)
~~~

This binds executable, permissions, platform, authentication, and secret
requirements to the package signature. Signing only the file tree would leave
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
to the child process. The protocol itself has no credential-value field and no
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
