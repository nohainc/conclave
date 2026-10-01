# First-Party Worker Catalog Contract v1

**Contract ID:** `firstPartyWorkerCatalogVersion: 1`  
**Status:** Product identity frozen by ADR-015; runtime implementation updated by Architecture v8 / ADR-018

**Implementation rule:** a normal local CLI integration is a Logical Worker
implemented by the generic CLI Worker Engine and an official signed Tool
Profile Release. Provider-specific native Worker binaries are predecessor
artifacts and are not an extension point for this catalog.

## Catalog

| Product type ID | User-facing name | v8 implementation | Cardinality per Workspace |
| --- | --- | --- | --- |
| `chatgpt` | ChatGPT | CLI Worker Engine + `chatgpt-codex` Profile -> Codex CLI | one stable catalog slot |
| `gemini` | Gemini | CLI Worker Engine + `gemini-antigravity` Profile -> `agy` | one stable catalog slot |

The product-facing identity remains `chatgpt` and `gemini`.

Workflows, Workstream bindings, scheduling, history, and AX UI use those logical
Worker IDs. They do not use Profile IDs, Engine versions, or provider executable
names as identity.

## Workspace Workers page

The current v1 UX remains fixed:

~~~text
ChatGPT
provider CLI version
readiness
[Test]
[Enabled/Disabled]

Gemini
provider CLI version
readiness
[Test]
[Enabled/Disabled]
~~~

Normal users do not:
- add arbitrary Worker types;
- choose Tool Profile releases;
- edit Profile JSON;
- select arbitrary executables.

Advanced Diagnostics may show:
- Engine version;
- Profile definition/release;
- Profile lifecycle channel;
- provider CLI version;
- last probe/test evidence.

Disabled and readiness remain independent states.

A disabled Worker can still be tested.

## Readiness ownership

Workspace owns local logical Worker state.

Engine + admitted Profile own provider-specific readiness behavior:
- provider executable discovery;
- version detection;
- passive authentication/config checks;
- live test;
- result/error normalization.

Workspace never runs provider commands directly.

Cloud receives only safe readiness/runtime projection.

## v8 implementation mapping

~~~text
chatgpt
  engineFamily: cli
  profileDefinitionId: chatgpt-codex

gemini
  engineFamily: cli
  profileDefinitionId: gemini-antigravity
~~~

The Profile release itself is selected by Workspace from trusted compatible
official releases.

Changing Profile release does not change the logical Worker ID.

## Provider authentication

Provider authentication remains owned by the installed provider CLI.

Conclave does not store/share provider subscription tokens in Cloud.

Examples:
- ChatGPT/Codex uses its locally configured Codex authentication.
- Gemini uses its locally configured Antigravity/Google authentication.

Workspace may show safe readiness guidance returned by Engine/Profile but does
not reimplement provider login flows.

## Model selection

Models are not Worker Types.

AX/Workstream assignment may select an optional model.

The Engine/Profile maps that model to the provider CLI only when supported.

No Profile may silently substitute a different model.

## Capabilities

The logical Worker advertises the safe intersection of:
- product/catalog capabilities;
- Profile capabilities;
- provider tool/version capabilities;
- Workspace local permissions.

Cloud scheduling must never assume a capability solely because the Worker Type
normally supports it.

## Version evidence

v8 distinguishes:

~~~text
logical Worker type
Engine version
Profile definition/release
provider CLI version
provider model
~~~

Only the first item is the product Worker identity.

## Migration from Worker Runtime v2

Before v8, ChatGPT and Gemini were compiled as separate provider-specific Dart
Worker executables.

Architecture v8 preserves:
- logical Worker IDs;
- local provider authentication;
- UI rows;
- Workstream bindings;
- readiness semantics;
- process isolation.

It supersedes:
- separate ChatGPT/Gemini Conclave binaries;
- per-provider native Worker release selection;
- provider integration code compiled separately for each logical Worker.

Do not add another first-party provider-specific native Worker executable to
this v1 catalog during the v8 migration.

## Future catalog expansion

Architecture v8 permits a future approved logical Worker to be added through:
- a Cloud product catalog entry;
- an Engine family;
- an official signed compatible Profile definition/release.

Normal users still cannot add arbitrary catalog entries in v8.

A new Worker may become visible without a Workspace binary update only after its
Profile has passed the same trust/testing/release process as existing official
Profiles.

## Development/testing scalability proof

The optional v8 development seed includes `fixture-worker`, a testing-channel
Logical Worker mapped to the `fixture-cli` Tool Profile Definition. Its v1
release payload and offline version, readiness, success, and error fixtures
live under `packages/tool-profile/test/fixtures/`. The generic Profile fixture
harness and CLI Worker Engine acceptance test exercise it without a new
Workspace or Engine implementation or a provider-specific Worker executable.
The entry is excluded from the stable catalog and is not an official user-facing
Worker.
