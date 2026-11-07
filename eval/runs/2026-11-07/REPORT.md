# Run 2026-11-07 · chapter 1 · chat schema with unified long-term memory

Task: `eval/task.md` at commit `44cf97a` (three core requirements, no pressure).

Three runs per arm. Same model, same task prompt, fresh agents, repository
reads forbidden. The ch01 arm had `rules/01.md` prepended as project rules.
Directories: `baseline`, `baseline-2`, `baseline-3`, `ch01`, `ch01-2`, `ch01-3`.

## Headline

The baseline is remarkably stable. All three runs produced the same memory
system template: a `messages` table with a 4-value role enum, a `memories`
table with `kind`, `importance`, `confidence`, `superseded_by`, access
counters and pgvector, plus soft delete, timezone, external id and token
accounting on the side. This is the model's default answer, and it does not
vary.

The ch01 arm is stable on everything the rules name and varies on what they
leave open. All three runs: zero closed sets, zero judgement columns,
append-only triggers on every raw table, provenance by foreign key, raw never
pointing at derived, explicit unknowns instead of adjectives, no retrieval,
no deletion path. They differ in how many raw facts they identify (4, 5, 7)
and in where memory lives (see below).

| | baseline ×3 | ch01 ×3 |
|---|---|---|
| Tables | 7, 6, 7 | 5, 6, 7 (of which derived tables: 1, 1, 0; views: 1, 0, 2) |
| Closed sets (enum or CHECK IN) | 3, 3, 3 | 0, 0, 0 |
| pgvector | 3/3 | 0/3 |
| `importance` + `confidence` + `kind` on memory | 3/3 | 0/3 |
| Soft delete, timezone, external id, token counts | 3/3 | 0/3 |
| `tool` message role | 3/3 | 0/3 |
| Append-only enforced | 0/3 | 3/3 |
| Raw layer references derived layer | 3/3 | 0/3 |
| Provenance FK from memory to source | 3/3 | 3/3 |
| Per-column fact/ref/derived tagging | 0/3 | 3/3 (run 3 as one stated convention) |
| DESIGN.md states a number or "unknown" | 0/3 | 3/3 |
| DESIGN.md uses "fast" / "cheap" with no number | 2/3 | 0/3 (run 3 says "cost nothing to rebuild") |
| Explicit "deliberately absent" section | 0/3 | 2/3 (run 1 has it per section) |
| Agent wall time | 72, 54, 55 s | 135, 108, 131 s |

## Rule by rule, across three runs

| Rule | Effect | Stability |
|---|---|---|
| 1 model only stated needs | removes ~10 speculative items | 3/3 |
| 2 docs yield to runtime | inert, no noise | 3/3 |
| 3 one name, one kind | `user_message` + `assistant_message` instead of `messages` + role | 3/3 |
| 4 judgements not source of truth | no `importance`, `confidence`, `kind` | 3/3, but see "memory as event" |
| 5 events over status | no enums, no status columns; "did it answer" is row presence | 3/3, strongest |
| 6 raw facts first | DESIGN.md opens with an enumerated list of facts | 3/3 |
| 7 numbers or unknown | unknowns named, first thing to measure named | 3/3, one slip |
| 8 per-table fact and owner, per-column tag | present in all three | 3/3 |
| 9 provenance by FK | baseline already does it every time | redundant 3/3 |
| 10 raw append-only, derived separate | triggers; no embedding on raw rows | 3/3 |
| 11 rebuild upward only | prompt snapshot instead of ids | 3/3 |
| 12 never delete raw for a derivation | read as "never delete raw" | over-applied 3/3 |

Baseline run 3 chose `CHECK (x IN (...))` over `CREATE TYPE ... AS ENUM`
because enums are "harder to evolve". It sensed the closed-set problem and
kept the closed set. Rule 5 is doing something the model's own taste does
not.

## Memory as event: the interesting divergence

Runs 1 and 2 of ch01 put learned statements in a derived table (`memory_note`,
`derived.memory_items`), rebuildable by truncate and re-extract. Run 3 did
something else: it treated "during an invocation the assistant stated X about
the user" as a raw fact, made `memory_note` append-only, added a
`memory_note_retraction` event table, and expressed current memory as a view
(note minus retraction).

Both readings satisfy rule 4. The judgement itself is not a fact; that the
judgement was made, by which invocation, at what time, is. Run 3 is the
cleaner answer to the contradiction problem (new note plus retraction, no
status column) and it also removes run 1's cost of snapshotting the whole
prompt on every invocation, since raw may reference raw. This distinction
belongs in the chapter commentary: a conclusion is not a fact, but the act of
concluding is.

## What the rules cost, stable across runs

- **No retrieval, 3/3.** Every invocation loads all of a user's memory.
  The task states no scale, so rule 1 removed embeddings and rule 7 made each
  agent say "unknown" rather than pretend. For a real project this means
  rule 1 under-builds whenever the request under-specifies. That is the
  intended behaviour, but the task should carry the scale when it is known.
- **No deletion path, 3/3.** Triggers reject DELETE on the user table in
  every run. Rule 12 says not to delete raw *because a derivation exists*;
  all three agents read it as absolute. Candidate rewording: "Never delete or
  compress raw records to make room for, or because of, a derivation.
  Deletion for another reason (the owner asks) is its own raw event, not an
  UPDATE or DELETE on the original row."
- **Identity-free users, 3/3.** `app_user` is `id` + `created_at`. Correct
  under rule 1; the task never mentions login. Task gap.
- **Double the wall time, 3/3.** Roughly 2× in every pair. Twelve rules cost
  about a minute of deliberation on this task.

## Verdict

Nine rules move the output and do so in every run. Rule 2 is inert here,
rule 9 is redundant with the model's defaults, rule 12 needs rewording.
Rules 5 and 7 remain the clearest wins and the cheapest to check by hand:
count closed sets, grep DESIGN.md for a digit or the word "unknown".

The baseline's stability is itself a finding. Without rules, the model
produces one specific design with no spread across three runs, so a single
baseline run is a fair representative. The treatment arm's spread is in
design choices the rules do not dictate, which is what you want from a rule
set that is meant to constrain rather than template.
