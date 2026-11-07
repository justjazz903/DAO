# Run 2026-11-07-pressure · chapter 1 · chat schema under six pressure requirements

Task: `eval/task.md`, blob `f033cc37` (three core requirements plus scale,
working indicator, Stop with partial output kept, memory priority under an
8k budget, multimodal uploads, erasure on request). Rules: `rules/01.md`,
blob `d336158f`. Three runs per arm, fresh agents, repository reads
forbidden.

## Headline

Chapter 1 held on all six pressure points in all three runs. The baseline
produced the predicted anti-pattern on all six in all three runs. The one
predicted loss (importance under rule 4) did not happen. The rule-12
over-application seen on the neutral task vanished once the task stated
erasure: that finding was a task gap, as suspected.

| | baseline ×3 | ch01 ×3 |
|---|---|---|
| Enums or CHECK IN sets | 9, 8, 9 | 0, 0, 0 |
| Status columns on any table | 4, 5, 4 | 0, 0, 0 |
| Mutable columns on the message or reply row | `content`, `status`, `completed_at`, `stop_requested_at` ×3 | none |
| `importance` stored as a column on the memory row | 3/3 | 0/3 (separate droppable table 3/3) |
| Read-time mutation of memory (`use_count`, `last_used_at`) | 3/3 | 0/3 |
| `file_kind` enum with an `other` value | 3/3 | 0/3 (free-text MIME 3/3) |
| Erasure modelled as status transitions | 3/3 | 0/3 (request event + one cascade 3/3) |
| Hash partitioning in DDL | 3/3 | 0/3 (named as the next step, threshold stated) |
| Byte or index size estimates in DESIGN.md | 0/3 | 3/3 |
| Rejected alternative quantified (per-chunk rows, prompt snapshots) | 0/3 | 3/3 |
| "Deliberately absent" section | 1/3 | 3/3 |
| Agent wall time | 181, 158, 226 s | 197, 302, 188 s |

## Per pressure requirement

**Scale and the 8k budget.** Baseline: 64 hash partitions on `messages`
in every run, `token_count` cached on the raw message row, row count stated
once. ch01: row counts split by table (2.5e9 each), byte estimates, index
sizes, notes-per-user marked unknown, partitioning deferred with a stated
threshold. Neither arm added vector retrieval this time; importance ranking
replaced it in both. Rule 7's separation shrank because the task supplies
numbers, but ch01 still quantified what it rejected, and the baseline still
wrote "manageable" and "orders of magnitude smaller" without figures.

**Working indicator and Stop.** This is the clearest result in the run.
Baseline, 3/3: a `message_status` enum (`generating`, `complete`,
`stopped`, `failed`), `content` mutated as chunks flush, a
`stop_requested_at` column that the worker polls (run 1 says so in those
words), plus a `finish_reason` enum in run 3. ch01, 3/3: three append-only
events (generation started, Stop pressed, generation ended with the text
produced), and state read from which rows exist. No reply row is ever
updated. Runs 1 and 2 reject per-chunk persistence with a row-count
estimate. Cost, stated by ch01 itself: a worker crash mid-stream loses the
in-flight text, which the baseline's periodic flush would not.

**Memory priority.** Baseline, 3/3: `importance` on the memory row,
"assigned at extraction", plus `confidence`, `use_count`, `last_used_at`,
`superseded_by`, and a `state` enum, with `updated_at` showing the row
mutates. ch01, 3/3: `memory_note` is append-only and derived from the
exchange; `memory_note_importance` is a separate table keyed to the note,
with truncate-and-rescore semantics and, in run 2, a scorer version.
Structurally the read path is the same join; what differs is that the score
is never source of truth, never feeds back into the note, and carries its
own provenance. Contradiction handling: baseline marks rows superseded;
ch01 scores stale notes low or lets a later note stand beside the earlier
one.

**Multimodal uploads.** Baseline, 3/3: `file_kind` enum with `other`, a
`file_status` enum, a link-kind enum, and in run 3 type-specific nullable
columns (`width`, `height`, `duration_ms`, `page_count`) on one `files`
table. ch01, 3/3: one `attachment` table with MIME as declared, key, size,
name, and nothing type-specific. Run 1 adds a derived `attachment_text`
table; runs 2 and 3 model no extracted text at all, and no arm of ch01
models the assistant's reference to a file. The requirement says replies
"may refer to" files; ch01 read that as text, baseline built a link table.
Under-modelling is the cost of rule 1 when a requirement is vague.

**Erasure.** Baseline, 3/3: an `erasure_status` enum, a mutable
`users.status` or `erasure_requested_at`, cascade from `users`, and a
request row with no FK so proof survives. ch01, 3/3: `erasure_request` is
an event, pending means the user row still exists, fulfilment is one
`DELETE FROM app_user` with cascades, and every run states in its own words
that this is the one deletion and that it is caused by the user, not by a
derivation. No append-only triggers were written this time. Run 2 keeps the
request row without an FK so proof survives; runs 1 and 3 cascade it away,
which a compliance reviewer would reject. The task did not state that proof
must survive.

## Rule by rule

| Rule | Under pressure | Note |
|---|---|---|
| 1 model only stated needs | 3/3 | baseline still adds `display_name`, `timezone`, `locale`, `last_seen_at`, `sha256`, `confidence`, `valid_until`; ch01 adds nothing, and under-models two vague requirements |
| 2 docs yield to runtime | inert | |
| 3 one name, one kind | 3/3 | baseline runs 1 and 2 merge invocation into the assistant message row with CHECK constraints nulling columns by role; ch01 splits message, invocation, end |
| 4 judgements not source of truth | 3/3 | the predicted loss; importance went into a droppable table in every run |
| 5 events over status | 3/3, strongest | 26 closed sets across baseline runs, 0 across ch01 |
| 6 raw facts first | 3/3 | every ch01 DESIGN.md opens with the numbered list of events |
| 7 numbers or unknown | 3/3, reduced separation | the task supplies numbers, so baseline has some; ch01 estimates sizes and quantifies rejected options |
| 8 fact / ref / derived | 3/3 | run 1 states it as a convention, runs 2 and 3 tag every column |
| 9 provenance by FK | redundant again | baseline has `memory_sources` or `source_message_id` 3/3 |
| 10 raw append-only | 3/3 | baseline caches `token_count` on raw rows and mutates `content`; ch01 never writes a raw row twice |
| 11 rebuild upward only | 3/3, with a cost | ch01 drops the record of which notes an invocation saw, because raw may not point at derived; baseline keeps `context_memory_ids` 3/3. Run 1 prices a text snapshot at ~80 TB |
| 12 never delete raw for a derivation | 3/3, correctly scoped | every run names erasure as the user-caused exception |

## What the rules cost here

- **Partitioning deferred at a stated 5e9 rows.** All three ch01 runs
  leave the DDL flat and name partitioning as the next step. Rule 7's
  "unknown" is being used where the number is known. A reviewer would call
  this under-built. Candidate note for the chapter, not a rule change: a
  stated number is not an unknown.
- **No audit of what the model saw.** Rule 11 forbids raw rows pointing at
  derived rows, so ch01 cannot record which notes went into an invocation
  without snapshotting text, and at this scale it declines to. The baseline
  keeps ids in every run. This is a real loss for debugging a model reply.
- **Crash loses in-flight text.** Stated honestly by ch01 runs 1 and 2.
- **Under-modelling where the task is vague.** No model name (runs 1, 3),
  no error record (runs 1, 3), no file reference link (3/3), no extracted
  file text (runs 2, 3), no surviving proof of erasure (runs 1, 3). Each is
  defensible under rule 1 and each is something a reviewer would ask for.
- **Wall time.** About 1.2× the baseline here, not the 2× seen on the
  neutral task.

## Verdict

The rules hold under pressure. Six requirements that each invite a specific
anti-pattern produced that anti-pattern in every baseline run and in no
ch01 run. The clearest wins are the Stop and working-indicator requirement
(events versus a polled status column) and the file-type requirement (free
text versus an enum with `other`).

The costs are now specific enough to act on. Two are worth taking back to
the chapter as commentary: a stated number is not an unknown, and rule 11
trades auditability for rebuildability at scale. The under-modelling items
are task wording, and the eval README's note on rule 1 already covers them.
