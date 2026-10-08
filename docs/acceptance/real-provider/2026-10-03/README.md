# Real-provider acceptance — 2026-10-03

## Profile evidence

The local Profile acceptance suite ran through the generic CLI Worker Engine
for both official Profiles. The complete Cloud-contract evidence is retained
beside this report:

| Profile | Provider CLI | Digest | Scenarios |
| --- | --- | --- | --- |
| `chatgpt-codex` | Codex CLI `0.158.0` | `96e7c7beb07baf21fd79d886df4900cade3678062549a8ed664310c413f30ccc` | Six passed; model selection and thread write not applicable under the declared capabilities. |
| `gemini-antigravity` | Antigravity CLI `1.2.14` | `9c62bfe732301d40534507a2e858d334f2cd0b7755a82706fdc60fe9e38fb780` | Six passed; model selection and thread write not applicable under the declared capabilities. |

The Codex fixture's declared supported range now covers `0.158.0` through
`0.189.x`, preserving its prior `0.180.x` fixture coverage while including the
installed CLI used for this run. This changes the fixture payload digest; it
does not change a published or signed Cloud Profile.

## Assignment matrix

| Workflow | Codex | Gemini |
| --- | --- | --- |
| Direct | Passed | Passed |
| Plan & Implement | Passed | Failed on final rerun (passed on initial run) |
| Implement & Verify | Passed | Blocked by headless command permission |
| Full Cycle | Passed | Blocked by headless command permission |

The final rerun passed one of four Gemini workflows. Plan & Implement passed on
the first run but failed on rerun, so it is not accepted as repeatable evidence.
The headless CLI reported that a shell command needed the `command` permission
and was auto-denied because no interactive approval can be shown. The
acceptance harness retained the bounded local diagnostic in its temporary test
directory. The CLI was not run with its all-tools permission bypass.

## Testing Workspace

The deterministic signed-release store check confirmed that a Cloud-selected
Testing channel activates its release without moving the Stable pointer. The
Mock Engine publication gate also passed by rejecting a candidate with no
qualifying Cloud evidence record.

No Cloud release was published and no remote Workspace channel was changed.
The Testing Workspace rollout remains gated on repeatably passing all four
Gemini assignment scenarios and publishing a release whose digest matches the
accepted Profile payload.
