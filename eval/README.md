# Eval method

Same task, same model, two runs. The only variable is whether the compiled
chapter rules are present as project instructions.

| Run       | Instructions                         | Output dir                    |
|-----------|--------------------------------------|-------------------------------|
| baseline  | `task.md` only                       | `runs/<date>/baseline/`       |
| ch01      | `rules/01.md` + task   | `runs/<date>/ch01/`           |

## Controls

- Both runs use a fresh agent with no conversation history.
- Both runs are forbidden from reading the repository, so neither can see the
  other's output, `start-here.md`, or the chapter commentary.
- The task prompt is neutral: it does not hint at any rule. If a rule's effect
  shows up in the baseline anyway, the rule is not doing work.
- One run per arm is a smoke test, not a result. Rerun at least three times
  per arm before claiming a rule changes behaviour.

## What to compare

Not a score. A checklist, filled in per run:

- Tables and columns: count, and which ones the task did not ask for.
- Stored conclusions: columns that hold a judgement or derived value
  (importance, relevance, category, score, flags) rather than an observed fact
  or a reference.
- Speculative structure: anything built for a requirement that is not in the
  task (sessions, multi-tenant orgs, soft deletes, versioning, audit tables).
- Stated non-goals: does `DESIGN.md` say what the schema deliberately leaves
  out?
- Load assumptions: are performance or scale choices tied to a stated number
  or an explicit unknown, or just asserted?
- How memory is modelled: raw observations vs pre-digested summaries, and
  whether the two are kept apart.

A rule earns its place only if it moves one of these in the ch01 arm and not
in the baseline arm.

## Discipline

A rule's wording changes only after it fails on two different tasks. A
failure on one task is recorded in the chapter next to the rule, with the
date and the task, and left there. This applies 名可名，非常名 to the rules
themselves: the label one eval gives a rule is not a permanent name.

The exception is a change that makes a rule more general (a word list
becoming a principle). That can follow a single run.

## Open questions

Recorded from runs, not yet answered. Each needs a task written to test it.

- **Append-only raw versus physical erasure.** Rules 10 and 12 produce an
  append-only raw layer. Any system that also has to erase data on request
  will contradict that. Not specific to chat; needs a task whose
  requirements state erasure. (2026-11-07)
- **Rule 1 under-builds when the task under-specifies.** With no scale in
  the task, every ch01 run dropped retrieval and said "unknown". That is
  the rule working as intended, but it means a request to an agent running
  these rules must carry the scale when it is known. A scaled variant of
  the task would show whether ch01 then builds retrieval and still states
  numbers. (2026-11-07)
