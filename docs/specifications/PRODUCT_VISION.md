# Product Vision

## Problem
High-quality AI-assisted software development often requires a human to manually split large requests into smaller prompts, consult several models, transfer context, ask coding agents to implement changes, request independent reviews, run tests, resolve feedback, and repeat.

## Vision
Conclave automates that coordination while keeping every step observable and verifiable.

A user communicates with Conclave conversationally, but Conclave internally manages a persistent **Goal**. The goal may span many model calls, chats, agent executions, tests, artifacts, and review cycles.

## First product: Conclave Forge
Forge focuses on software development and should:
1. understand a repository and requested outcome;
2. divide work into small phases/tasks;
3. delegate research and implementation to suitable workers;
4. use isolated independent review;
5. turn review findings into corrective tasks;
6. execute real tests/checks where available;
7. repeat until completion policy is satisfied;
8. return a concise final report with evidence and remaining risks.

## Quality philosophy
Conclave cannot guarantee correctness. Instead it must make acceptance evidence-based:
- independent verification where appropriate;
- explicit unresolved findings;
- machine-generated test/build evidence;
- traceable decisions and artifacts;
- configurable quality/verification policies.

## User experience
The user should be able to start with a message such as:

> Investigate why scheduler backlog days are not settled, fix the issue, add tests, and verify the result.

The user may then observe progress, answer questions or approvals when required, and receive the final verified result without manually coordinating every AI worker.
