# Tool Profile v1 Specification

**Status:** Architecture v8 normative profile contract  
**Architecture:** [Architecture v8](../architecture/ARCHITECTURE_V8.md)  
**Decision:** [ADR-018](../decisions/ADR-018-generic-cli-worker-engine-and-tool-profiles.md)

## 1. Purpose

Tool Profile v1 is the declarative contract used by the generic Conclave CLI
Worker Engine to integrate one approved local CLI tool.

A Profile release is immutable, signed, independently versioned, provider/tool
specific, and constrained by a finite schema. It is never arbitrary executable
code.

## 2. Design principles

1. Arguments are structured arrays, never shell command strings.
2. Profiles never enable shell execution.
3. Placeholders come from a closed list.
4. Selectors use a bounded JSON-path-like syntax implemented by the Engine.
5. Match/action rules use a fixed finite operation set.
6. Profiles cannot define loops, arbitrary expressions, arbitrary file I/O,
   network access, or helper subprocesses. The sole bounded filesystem read is
   the typed local JSON config check defined in section 9.1.
7. Engine hard limits override Profile values.
8. Material provider behavior changes should prefer a new Profile release over
   large in-profile branching.
9. Profile releases are tested like code.
10. Normal users do not edit official Profiles.

## 3. Top-level shape

Conceptual JSON:

~~~json
{
  "schemaVersion": 1,
  "profileDefinitionId": "chatgpt-codex",
  "releaseVersion": 10,
  "logicalWorkerTypeId": "chatgpt",
  "engineFamily": "cli",
  "engineCompatibility": {
    "min": "1.2.0",
    "maxExclusive": "2.0.0"
  },
  "providerTool": {},
  "environment": {},
  "probe": {},
  "execution": {},
  "session": {},
  "model": {},
  "timeout": {},
  "sandbox": {},
  "progress": {},
  "errors": {},
  "capabilities": [],
  "compatibilityOverrides": []
}
~~~

Unknown fields are rejected unless a later schema version explicitly permits
extensions.

The canonical v1 validator and inferred TypeScript model are maintained
together in [`packages/tool-profile/src/index.ts`](../../packages/tool-profile/src/index.ts).
The same source exports a JSON Schema representation. Its engine-owned bounds
are published as `TOOL_PROFILE_LIMITS`; the validator rejects payloads over
256 KiB and rejects unknown fields at every Profile-defined object.

### 3.1 Schema evolution gate

Profile v1 is closed. Do not add optional escape hatches, expressions, scripts,
or provider-only interpreter branches to make one integration fit. For an
unsupported CLI behavior, the proposal must:

1. document the concrete provider behavior and the missing v1 primitive;
2. test whether the behavior is generic across integrations, using at least a
   fixture CLI/Profile where practical;
3. justify any integration-specific handling and explain why bounded Profile
   data cannot represent it safely;
4. update the [security threat model](../security/V2-28-threat-model.md) with
   the new authority, inputs, and resource bounds before implementation;
5. add schema v2 only when the behavior needs new Profile semantics that cannot
   be expressed by the existing finite v1 primitives.

When v2 is justified, it must have its own strict versioned validator and
interpreter semantics. v1 payloads continue through the unchanged v1 validator;
they are never reinterpreted as v2, and neither validator accepts unknown
fields. Workspace and Engine reject unsupported schema versions before
execution. Profile releases remain immutable and signed over the schema
version and complete behavior payload. No schema v2 is defined by this
specification.

## 4. Identity

Required:

~~~text
schemaVersion
profileDefinitionId
releaseVersion
logicalWorkerTypeId
engineFamily
~~~

Constraints:
- identifiers are bounded stable IDs;
- releaseVersion is a positive monotonic integer within one definition;
- engineFamily v1 is `cli`;
- logicalWorkerTypeId matches the admitted Worker catalog entry.

## 5. Engine compatibility

~~~json
{
  "engineCompatibility": {
    "min": "1.2.0",
    "maxExclusive": "2.0.0"
  }
}
~~~

Workspace/Engine rejects a Profile outside the running Engine version range.
Semantic-version checks use full SemVer precedence, including prerelease
ordering; build metadata does not affect compatibility. Both Engine and
Workspace use the shared Tool Profile v1 comparator.

## 6. Provider tool declaration

Conceptual:

~~~json
{
  "providerTool": {
    "name": "Codex CLI",
    "executableCandidates": ["codex"],
    "discovery": {
      "standardLocations": [
        "{{home}}/.local/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin"
      ],
      "allowPathSearch": true
    },
    "versionProbe": {
      "arguments": ["--version"],
      "timeoutMs": 10000,
      "source": "stdout",
      "extract": {
        "kind": "regex_capture",
        "patternId": "semver"
      }
    },
    "supportedVersions": [
      {
        "min": "0.176.0",
        "maxExclusive": "0.190.0"
      }
    ]
  }
}
~~~

### 6.1 Discovery restrictions

- executable candidate names cannot contain path separators;
- arbitrary Profile absolute executable paths are forbidden;
- standard locations may use approved path placeholders only;
- Engine owns maximum path count/search depth;
- Workspace/Engine may add generic safe OS locations;
- a cached absolute path may be tried first only after checking its identity,
  path bounds, expected executable name, and executable status again;
- when `allowPathSearch` is true, Engine searches the inherited OS `PATH`
  independently of the environment keys passed through to the provider;
- no Conclave-specific environment variable is required for discovery.

Engine generic locations include the common user CLI directories under the OS
home directory and standard system locations such as `/opt/homebrew/bin`,
`/usr/local/bin`, `/usr/bin`, and `/bin` on macOS. These are added by Engine;
Profiles do not need to enumerate every normal installation location.

## 7. Closed placeholders

Tool Profile v1 may use only approved placeholders:

~~~text
{{prompt}}
{{model}}
{{sessionId}}
{{timeoutMs}}
{{timeoutSeconds}}
{{workingDirectory}}
{{home}}
{{workerStateDirectory}}
~~~

The Engine performs substitution without invoking a shell.

Unknown placeholders fail Profile validation.

No nested expressions or function calls exist.

At execution time a missing value for a referenced placeholder is a controlled
Profile execution failure. `timeoutMs` expands to
`max(1, assignmentTimeoutMs - providerReserveMs)`; `timeoutSeconds` is the
ceiling of that value in seconds, with a minimum of one.

## 8. Environment

Conceptual:

~~~json
{
  "environment": {
    "passthrough": [
      "CODEX_HOME",
      "XDG_CONFIG_HOME"
    ],
    "set": {
      "NO_COLOR": "1"
    }
  }
}
~~~

Rules:
- passthrough names must satisfy Engine environment policy;
- reserved Conclave/Cloud secret variables cannot be requested;
- complete parent environment inheritance is forbidden;
- constant values are bounded;
- approved placeholders may be used where the schema permits;
- Profiles cannot remove Workspace-enforced baseline/safety values.

The Engine constructs the final provider environment.

## 9. Passive probe

A passive probe must not invoke a provider model.

Conceptual:

~~~json
{
  "probe": {
    "passive": {
      "checks": [
        {
          "id": "authentication",
          "arguments": ["login", "status"],
          "timeoutMs": 10000,
          "successExitCodes": [0],
          "failureIssueCode": "provider_authentication_required"
        }
      ]
    }
  }
}
~~~

The already-resolved provider executable is always used. A Profile cannot
execute a second arbitrary program for probes.

### 9.1 Bounded local config check

A passive probe may read a small JSON file below the Engine-approved local home
directory through `configChecks`. A check must declare `root: "home"`, a
relative path with no `.`/`..` segments, `format: "json"`, and a `maxBytes`
value no greater than 64 KiB. The Engine opens only that file, parses bounded
JSON, applies the same property-only selectors as event rules, and returns
only a passed/warning/failed state and stable issue code. It never exposes file
contents to Cloud or the UI. Missing, malformed, and oversized files are
handled by declared finite outcomes. No globbing, directory listing, symlink
traversal, arbitrary roots, or other file reads are permitted. Required
environment variables can be checked by name for non-empty values using
`requiredEnvironmentAny`; if none are present, the rule's explicit
`whenEnvironmentMissing` result applies. A missing file or home directory uses
`onMissing` and does not imply an authentication failure unless that outcome
is explicitly `failed`. The conditions and no-match result make the config
decision exhaustive. Values are never returned.

## 10. Live probe

Live probe uses normal Profile execution with a Conclave-controlled test
request and a hard 30-second timeout ceiling:

~~~text
Reply with exactly the word OK. Do not use tools.
~~~

The Engine owns the prompt and exact expected final text `OK`. Profiles cannot
change either. The Engine runs the Profile's normal transport and output parser
with a stateless session, applies the remaining request deadline, and fails
closed when the final text does not exactly match `OK` after trimming.

Live tests are explicit because they may consume provider quota.

## 11. Execution arguments

Conceptual Codex-like Profile:

~~~json
{
  "execution": {
    "arguments": [
      "--ask-for-approval", "never",
      {"sandboxPolicyMapping": true},
      "exec",
      "--json",
      "--color", "never",
      "--skip-git-repo-check",
      "--cd", "{{workingDirectory}}",
      {"modelArguments": true},
      {"sessionResumeArguments": true},
      {"ifAbsent": "sessionId", "ifSessionPolicy": "stateless",
       "values": ["--ephemeral"]},
      {"providerTimeoutArguments": true},
      "-"
    ],
    "stdin": {
      "mode": "raw_text",
      "value": "{{prompt}}"
    },
    "output": {
      "mode": "jsonl"
    }
  }
}
~~~

Conditional argument forms are fixed schema constructs, not expressions.
Every execution argument list has exactly one
`{"sandboxPolicyMapping": true}` slot. The Engine replaces it with the
arguments mapped for the authorized execution policy, preserving provider CLI
argument position. It also contains one `{"providerTimeoutArguments": true}`
slot and contains one `{"modelArguments": true}` slot when model arguments are
declared, plus one `{"sessionResumeArguments": true}` slot when sessions are
supported. These markers insert the corresponding section's fixed argument
vector at that position. The profile's `sandbox.mappings` define finite vectors
for `restricted`, `provider_default`, and `full_access`.

Allowed v1 conditions are limited to:
- known field present/absent, equals/not-equals, one-of bounded constants, or
  has a JSON value type;
- session policy equality;
- bounded Engine-defined execution policy.

## 12. JSON stdin template

For tools requiring structured stdin:

~~~json
{
  "stdin": {
    "mode": "json_object",
    "value": {
      "event": "user",
      "message": {
        "content": "{{prompt}}"
      }
    },
    "appendNewline": true
  }
}
~~~

The Engine serializes JSON. Profiles do not interpolate raw JSON strings.

## 13. Output modes

Tool Profile v1 supports:

~~~text
plain_text
single_json
jsonl
~~~

For `jsonl`, each bounded line is decoded as one JSON value.
Blank lines are ignored. A malformed non-empty line or output exceeding Engine
limits is a controlled provider failure. The v1 interpreter bounds prompt and
stdin at 1 MiB, expanded argv bytes at 128 KiB, total output at 4 MiB, each
JSONL line at 512 KiB, event count at 10,000, and normalized final text at 512
KiB. Session IDs are limited to 256 characters.

Required structured output that cannot be decoded is a controlled execution
failure.

## 14. Selectors

Profiles use a bounded selector syntax such as:

~~~text
$.type
$.thread_id
$.item.type
$.item.text
$.result.status
$.result.response
~~~

v1 selectors:
- begin at root;
- allow object-property traversal only;
- address own JSON data properties only and reject prototype properties;
- have bounded depth/length;
- do not support filters;
- do not support recursive descent;
- do not support script expressions.

## 15. Event rules

Finite rules map provider events into Engine semantics.

Progress rules are evaluated in source order and the first matching rule
wins. Profiles must put specific rules before a broader fallback. This makes
the Gemini `agent_response` mapping deterministic.

Conceptual:

~~~json
{
  "events": [
    {
      "when": [
        {"kind": "equals", "selector": "$.type", "value": "thread.started"}
      ],
      "actions": [
        {"type": "set_session", "selector": "$.thread_id"}
      ]
    },
    {
      "when": [
        {"kind": "equals", "selector": "$.type", "value": "item.completed"},
        {"kind": "equals", "selector": "$.item.type", "value": "agent_message"}
      ],
      "actions": [
        {"type": "set_final_text", "selector": "$.item.text"}
      ]
    }
  ]
}
~~~

Allowed actions v1:

~~~text
set_session
set_final_text
set_terminal_status
set_provider_error
emit_progress
mark_success
mark_failure
~~~

No arbitrary state mutation is permitted.

## 16. Terminal result contract

A Profile makes terminal success/failure unambiguous.

Examples:

~~~text
success:
event=result AND result.status=SUCCESS
~~~

or:

~~~text
success:
turn.completed observed AND final text exists
~~~

The Engine requires one bounded final result for successful execution.
For structured output, success requires exit code zero, a `mark_success` action,
and non-empty final text. `mark_failure`, a provider error, cancellation, or an
Engine timeout makes the terminal result fail. For `plain_text`, a non-empty
text result and exit code zero are sufficient. A failed result uses the first
matching Profile error mapping, except Engine cancellation/deadline outcomes,
which take precedence.

The interpreter returns the same bounded result shape for each output mode:
terminal success/failure, final text, observed session ID, terminal status,
Engine message-key progress entries, and an optional stable issue code.

## 17. Progress mapping

Conceptual:

~~~json
{
  "progress": [
    {
      "when": [{"kind": "equals", "selector": "$.type", "value": "turn.started"}],
      "percentage": 10,
      "messageKey": "provider_working"
    }
  ]
}
~~~

Profiles select Engine-owned safe message keys. Raw provider event content is
not forwarded as user-visible progress.

## 18. Session rules

Conceptual:

~~~json
{
  "session": {
    "supported": true,
    "formatId": "codex-thread-v1",
    "compatibleFormatIds": ["codex-thread-v1"],
    "extract": "$.thread_id",
    "resumeArguments": ["resume", "{{sessionId}}"],
    "requireObservedIdMatch": true
  }
}
~~~

The Engine implements continuity validation.

When durable session is requested:
- an observed provider session ID must exist;
- resumed observed ID must equal the stored expected ID;
- mismatch is a hard session-resume failure.

`formatId` identifies the provider's local session-ID format. A Profile Release
must include its own format in `compatibleFormatIds`; it may include an older
format only when it declares that ID safe to resume. The Engine partitions
session records by logical Worker, Profile definition, provider tool identity,
and logical Conclave `sessionKey`. It resumes a stored provider ID only when
the active Profile declares that stored format compatible. Otherwise it starts
without the stored provider ID and replaces the local mapping after a
successful new durable session. Profile release metadata never changes the
signed compatibility declaration. Session files written by the unpartitioned
development Engine are ignored by this format and will begin a fresh provider
session on first use.

## 19. Model mapping

Conceptual:

~~~json
{
  "model": {
    "supported": true,
    "arguments": ["--model", "{{model}}"],
    "unknownModelPolicy": "pass_through"
  }
}
~~~

v1 may support:
- `pass_through`;
- `profile_allowlist`.

No silent model substitution is permitted.

## 20. Timeouts

A Profile may map the assignment timeout to a provider argument:

~~~json
{
  "timeout": {
    "providerArguments": ["--print-timeout", "{{timeoutSeconds}}s"],
    "providerReserveMs": 1500
  }
}
~~~

For `{{timeoutSeconds}}`, the Engine supplies
`max(1, ceil((assignmentTimeoutMs - providerReserveMs) / 1000))`. The provider
reserve is independent from the Engine's own hard process deadline and cleanup
grace. The Engine deadline always wins if the CLI ignores its provider timeout.
The Engine owns the cleanup grace; Profiles cannot change it.

## 21. Sandbox/permission mapping

Profile maps an Engine-approved execution policy:

~~~text
restricted
provider_default
full_access
~~~

to bounded provider arguments.

`full_access` is usable only when Workspace/product policy explicitly permits
it. A Profile cannot independently broaden local permissions.

## 22. Error mappings

Profiles may map bounded provider evidence to stable Conclave issue codes.

Evidence types v1:
- exit code;
- terminal status value;
- Engine-approved bounded stderr matcher/pattern;
- missing terminal result;
- structured provider-error selector.

Stable codes include:

~~~text
provider_authentication_required
provider_tool_unavailable
unsupported_provider_tool_version
model_not_supported
permission_denied
quota_exhausted
provider_unavailable
deadline_exceeded
cancelled
session_resume_failed
provider_failure
~~~

## 23. Version-specific overrides

A release may contain small bounded compatibility overrides.

Requirements:
- bounded number;
- non-overlapping provider-version ranges;
- only `executionArguments`, `versionProbeArguments`, `progress`, and
  `errorMappings` may be overridden in v1;
- fixtures for every range.

Materially different behavior should become a new Profile release instead.

## 24. Capabilities

Profile declares safe product capabilities such as:

~~~text
text
local_file
workstream_read
workstream_write
durable_session
image
audio
video
~~~

Engine/Workspace intersect Profile claims with actual local/product permissions.

A Profile cannot grant capabilities forbidden by Workspace.

## 25. Profile release envelope

Workspace verifies a Tool Profile Release v1 envelope before passing the
payload to the generic CLI Worker Engine. The payload digest is lowercase
hexadecimal SHA-256 over the canonical JSON encoding of the complete validated
Profile v1 object. The Ed25519 signature is over UTF-8 bytes of:

~~~text
conclave-tool-profile-release-v1\n<canonical envelope JSON>
~~~

The canonical envelope JSON has exactly these signing claims:

~~~text
domain = conclave-tool-profile-release-v1
publisher
signingKeyId
payloadDigest
profileDefinitionId
releaseVersion
logicalWorkerTypeId
engineFamily
schemaVersion
engineCompatibility
providerToolName
providerCompatibility
~~~

`providerCompatibility` is the signed payload's
`providerTool.supportedVersions`. Workspace recomputes the payload digest,
compares every repeated envelope claim against the payload and Cloud release
metadata, then checks the publisher/key ID against its Ed25519 trust roots.
Changing behavior, identity, release version, logical Worker binding, Engine
compatibility, provider compatibility, publisher, or key ID invalidates
admission.

Lifecycle state, channel, promotion pointers, audit fields, display name, and
timestamps are registry metadata outside the signed envelope. Workspace may
accept a trusted signed release at a permitted channel, but those fields cannot
change signed behavior or compatibility claims. Workspace also rejects a
revoked payload digest, `<profileDefinitionId>@<releaseVersion>`, publisher, or
signing key ID. Key rotation adds a new key ID and public key to the Workspace
trust roots before signing with it; key IDs cannot be relabeled after signing.

## 26. Immutability

Once a Profile release is published beyond draft:
- payload bytes do not change;
- compatibility claims do not mutate in place;
- correction requires a new release;
- lifecycle state/pointers may change;
- revocation metadata may be appended.

## 27. Validation levels

### Static validation

- exact schema;
- bounds;
- identifiers;
- placeholders;
- selectors;
- actions;
- compatibility ranges;
- forbidden environment names;
- forbidden shell constructs.

### Fixture validation

- version parsing;
- passive probe;
- normal result extraction;
- errors;
- progress;
- session start/resume;
- version-specific variations.

### Real acceptance

- real installed provider CLI;
- passive probe and explicit live probe;
- representative assignment and Workstream write where the Profile can write
  local files;
- durable session start and resume when the Profile supports sessions;
- bounded timeout and assignment cancellation through the Workspace process
  tree supervisor.

Stable promotion for first-party official Profiles requires all applicable
levels. The controlled acceptance runner records a JSON evidence artifact bound
to the exact Profile digest, release identity, Engine version, provider CLI
version, and required scenario results. Evidence must be no older than 90 days
and must use Engine/provider versions allowed by the signed Profile. The stable
promotion API requires this artifact and retains it as immutable release
evidence. Normal CI must not enable real acceptance or consume provider
allowance.

Run one controlled profile from `apps/host` with:

~~~sh
CONCLAVE_TEST_REAL_PROFILE_CHATGPT=1 \
CONCLAVE_PROFILE_ACCEPTANCE_EVIDENCE_DIR=/secure/path/profile-evidence \
flutter test test/tool_profile_real_acceptance_test.dart
~~~

Use `CONCLAVE_TEST_REAL_PROFILE_GEMINI=1` for the Gemini Profile. The evidence
artifact contains version and scenario metadata only; it does not retain
credentials, prompts, provider output, or Workstream file contents.

## 28. Initial official Profiles

Architecture v8 starts with:

~~~text
chatgpt-codex
gemini-antigravity
~~~

They must reproduce the already-passing provider-specific Dart Worker behavior
before those provider-specific binaries are removed.

## 29. Non-goals

Tool Profile v1 is not:
- a shell script format;
- a Workflow language;
- a prompt-template product;
- user-editable v8 functionality;
- arbitrary plugin code;
- a permission bypass mechanism;
- a replacement for future non-CLI Engine families.

## 30. Evolution rule

If Profile v1 cannot represent a provider safely:

1. If the missing concept is generic across multiple CLI tools, add a typed
   Engine/Profile capability in a new schema version.
2. If it is provider-specific, prefer a specialized driver/engine rather than
   making the Profile schema a programming language.

## 31. Machine bounds

The canonical validator publishes the exact hard limits in
`TOOL_PROFILE_LIMITS`. In v1 these include: 256 KiB serialized payload; 4,096
characters per general string; 256 characters per short label; 64 items per
general array; 128 arguments; 128 event rules; 64 progress and error rules;
16 selector conditions per rule; selector depth 16 and selector length 256;
JSON template nesting depth 16;
64 environment names; 8 config checks with a 64 KiB maximum file size; and
16 compatibility overrides. More specific schema fields may have tighter
limits. Pattern IDs are finite Engine-owned enum values, not user-provided
regular expressions.

## 32. Deterministic rule processing

Event rules and progress rules are evaluated in Profile source order. Event
actions within a matched rule execute in source order. A progress event emits
the action from the first matching progress rule only. Stable failure mappings
are ordered; the Engine uses the first matching mapping. An Engine may still
report its own hard deadline or protocol-integrity failure regardless of
Profile mappings.
