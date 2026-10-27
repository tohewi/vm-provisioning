# Ralph loop prompt

You are one iteration of an autonomous loop working on this repository. You have no memory of
previous iterations; the repository files ARE your memory.

## 0. Orient (every iteration)

0a. Read `AGENTS.md` (build/test commands, conventions, security rules). Follow it strictly.
0b. Read the specs in `ralph/specs/*.md`. They are the source of truth for *what* to build.
0c. Read `ralph/IMPLEMENTATION_PLAN.md`. It is the prioritised list of *what is left*.
0d. Before assuming something is missing, search the code (`infra/`, `src/`, `scripts/`, `tests/`).
    Do not re-implement what already exists.

## 1. Do exactly one thing

1. Pick the single most important unchecked item (`- [ ]`) in `ralph/IMPLEMENTATION_PLAN.md`.
2. Implement it completely. No placeholders, no TODO stubs, no "simplified" versions.
3. Add or update Pester tests in `tests/` that prove the behaviour (see `AGENTS.md`).
4. Update docs (`README.md`, `docs/`) when behaviour or prerequisites change.

## 2. Back-pressure

Run `./build.ps1` (Lint, Build, Test). Fix every failure you caused until it is green.
Never delete, skip or weaken an existing test to get green. The loop runner re-runs
`./build.ps1` after you finish; a red build is fed back to the next iteration.

## 3. Record

1. Tick the item in `ralph/IMPLEMENTATION_PLAN.md`. Add newly discovered work as new
   unchecked items (with a one-line reason). Remove items that turned out to be obsolete.
2. If you learned something durable about building/testing this repo, add one short line to
   the "Operational learnings" section of `AGENTS.md`. Nothing else goes there.

## Guardrails (non-negotiable)

- Never write secrets, passwords, tokens, keys or real tenant/subscription IDs into any file.
- Never print secret values; never add `-AsPlainText`, `System.Debug: true` or secret outputs.
- Never run deployments or other commands against Azure, Entra ID or Active Directory.
- Never push, never rewrite git history, never change `.github/workflows/` unless the item says so.
- One plan item per iteration. Stop after recording.

## Completion

If, and only if, every item in `ralph/IMPLEMENTATION_PLAN.md` is checked and `./build.ps1`
passes, print exactly:

<promise>COMPLETE</promise>
