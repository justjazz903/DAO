# Design

## Raw facts first

Four things actually happen, and each gets one append-only table:

1. A person registered (`app_user`).
2. A user sent text (`user_message`).
3. The application sent a request to the model, with the exact input it assembled (`llm_invocation`).
4. The model answered (`llm_response`).

Everything else is derived from these.

## Memory is derived, never source of truth

"What the assistant learns" is an interpretation. `memory_note` is a derived table: each row is one statement extracted from one exchange and carries a foreign key to the `llm_invocation` it came from. The whole table can be truncated and rebuilt by re-running extraction over every invocation and response.

Contradictions ("I live in Paris" then "I moved to Berlin") are not resolved by status columns. There is no `superseded_by`, no `active` flag. All notes are kept and handed to the model in chronological order; the model reconciles at read time. If reconciliation later needs its own structure, it becomes a further derived table above `memory_note`, not a column on it.

## Context without sessions

There is no session or conversation table. Each invocation reads all of the user's memory notes plus a transcript window (window size: unknown, decided by the application) and writes the assembled input into `llm_invocation.prompt_input`. That column is a fact (what was sent), not a reference: raw rows never point at derived rows, because derived rows can be dropped and their ids change.

## No status

"Did the model answer?" is the presence of an `llm_response` row. The transcript is a view over `user_message` and `llm_response`, not a stored table.

## Append-only

Triggers reject UPDATE and DELETE on the four raw tables.

## Numbers

Per invocation: one index range scan on `memory_note (user_id, id)` and one on `user_message (user_id, sent_at)`. Notes per user: unknown. `prompt_input` size per row: unknown; it grows with the note count, which is the first thing to measure.
