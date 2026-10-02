# Product Vision

## Problem

Software work involving AI often requires people to divide requests into
smaller tasks, coordinate tools and reviewers, run checks, and track the
resulting changes and evidence across multiple sessions.

## Vision

Conclave helps people direct that work through persistent Projects and
Workstreams. People discuss intent, start constrained Workflows, observe
execution, review changes and evidence, and decide what happens next. Conclave
keeps ownership of shared state and validates each transition.

Conclave Cloud coordinates shared product state. Conclave Workspace provides
the local execution environment. Logical Workers run through a generic CLI
Worker Engine and approved Tool Profiles, with provider CLI credentials staying
on the user's machine.

## Quality philosophy

Conclave does not guarantee AI correctness. It makes work inspectable and
acceptance evidence-based through:

- explicit Workstream state and execution policy;
- visible progress, artifacts, and decisions;
- machine-generated test and build evidence;
- independent verification where appropriate;
- clear unresolved findings and user-controlled approvals.

## User experience

People should be able to describe a goal, follow its Workstream, answer
questions or approvals when needed, and review the completed work without
manually coordinating every execution detail. Work remains attributable to its
Project and Workstream, with current state and evidence available for later
review.
