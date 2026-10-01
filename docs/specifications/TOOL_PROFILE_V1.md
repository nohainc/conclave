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
6. Profiles cannot define loops, arbitrary expressions, file I/O, network
   access, or helper subprocesses.
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
  "progress": {},
  "errors": {},
  "capabilities": []
}
~~~

Unknown fields are rejected unless a later schema version explicitly permits
extensions.

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
- a cached previously verified absolute path may be tried first.

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
          "command": {
            "arguments": ["login", "status"],
            "timeoutMs": 10000
          },
          "success": {
            "exitCodes": [0]
          },
          "failureIssueCode": "provider_authentication_required"
        }
      ]
    }
  }
}
~~~

The already-resolved provider executable is always used. A Profile cannot
execute a second arbitrary program for probes.

## 10. Live probe

Live probe uses normal execution with a Conclave-controlled test request:

~~~text
Reply with exactly the word OK. Do not use tools.
~~~

The Profile may select an execution variant, expected final-text matcher, and
shorter timeout. It may not replace the controlled test request.

Live tests are explicit because they may consume provider quota.

## 11. Execution arguments

Conceptual Codex-like Profile:

~~~json
{
  "execution": {
    "arguments": [
      "--ask-for-approval", "never",
      "--sandbox", "workspace-write",
      "exec",
      "--json",
      "--color", "never",
      "--skip-git-repo-check",
      "--cd", "{{workingDirectory}}",
      {"ifPresent": "model", "values": ["--model", "{{model}}"]},
      {"ifPresent": "sessionId", "values": ["resume", "{{sessionId}}"]},
      {"ifAbsent": "sessionId", "ifSessionPolicy": "stateless",
       "values": ["--ephemeral"]},
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

Allowed v1 conditions are limited to:
- known field present/absent;
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
- have bounded depth/length;
- do not support filters;
- do not support recursive descent;
- do not support script expressions.

## 15. Event rules

Finite rules map provider events into Engine semantics.

Conceptual:

~~~json
{
  "events": [
    {
      "when": [
        {"selector": "$.type", "equals": "thread.started"}
      ],
      "actions": [
        {"type": "set_session", "selector": "$.thread_id"}
      ]
    },
    {
      "when": [
        {"selector": "$.type", "equals": "item.completed"},
        {"selector": "$.item.type", "equals": "agent_message"}
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

## 17. Progress mapping

Conceptual:

~~~json
{
  "progress": [
    {
      "when": [{"selector": "$.type", "equals": "turn.started"}],
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
    "reserveMsForCleanup": 1800
  }
}
~~~

Engine validates reserve bounds and remains the authoritative process deadline.

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
session_resume_failed
provider_failure
~~~

## 23. Version-specific overrides

A release may contain small bounded compatibility overrides.

Requirements:
- bounded number;
- non-overlapping provider-version ranges;
- only explicitly overrideable fields;
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

The signed release envelope contains at minimum:

~~~text
profileDefinitionId
releaseVersion
schemaVersion
logicalWorkerTypeId
engineFamily
payloadDigest
signingKeyId
signature
~~~

The behavior payload is covered by the digest/signature.

Lifecycle state and promotion metadata may be stored alongside the immutable
signed payload.

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
- passive probe;
- explicit live probe;
- representative execution;
- durable session when supported.

Stable promotion for first-party official Profiles requires all applicable
levels.

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
