# V2-26 — Two-Agent distributed Forge

`multi_agent` is an explicit Forge execution mode for proving distributed orchestration:

```text
Agent MacBook / Codex       Agent Linux / Claude
          │ research A       │ research B
          └──────────┬────────┘
                     ↓
                 synthesis
                     ↓
               implementation
                     ↓
                   review
                     ↓
                   tests
```

The selected workers must use local-agent connections and resolve to at least two connected Agents. Forge selects a repository-read worker on an Agent different from the lead, forces the secondary research task, and passes both accepted research results into planning. Implementation and review remain separate worker resources, and runtime changes/tests continue through the approved Local Runtime channel.

This mode rejects direct cloud model workers. It is distinct from `single_agent`, while `cloud_api` remains an explicit compatibility mode rather than an automatic fallback.
