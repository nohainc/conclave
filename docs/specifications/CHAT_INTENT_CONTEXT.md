# Chat Intent and Scoped Context

**Status:** Normative Architecture v2 specification

## Message lifecycle

Every user Chat message is classified into exactly one proposed intent:

- `conversation` — answer from accepted project/run state when possible;
- `new_goal` — create an independent Goal in the current Chat;
- `continue_goal` — provide input to a Goal that is waiting;
- `approval` — answer an explicit approval or question from a waiting Goal;
- `follow_up_goal` — create a new Goal that references a completed or superseded Goal.

An AI Worker may propose the intent, but the proposal is untrusted. Core validates
the referenced Chat and Goal state and accepts only legal transitions. An invalid
proposal becomes a clarification response; it cannot mutate Goal or Run state.

## Context assembly

Workers do not receive the complete Chat transcript. Core builds a bounded
context from:

1. the current message;
2. accepted Decisions and results;
3. relevant Artifacts;
4. Project instructions;
5. explicit user references.

The context builder deduplicates IDs, applies item and character/token limits,
and preserves source IDs for audit. Speculative messages and rejected Worker
outputs are not implicitly promoted into context.
