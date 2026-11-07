# Design

## Raw facts first

The system records seven kinds of events, each its own table, each owned by whoever caused it:

1. an account was created (`app_user`)
2. the user sent a message (`user_message`)
3. the user attached a file to it (`attachment`; bytes in the object store, key in the row)
4. the application called the model for that message (`invocation`)
5. the user pressed Stop (`stop_request`)
6. generation halted and this text existed at that moment (`assistant_reply`)
7. the user asked for erasure (`erasure_request`)

Nothing in this layer is a status. "Assistant is working" is an invocation with no reply. "Stopped early" is a reply whose invocation has a stop request. "Erasure pending" is a request whose user row still exists.

## Derived structure

Memory is derived from the messages, never written directly:

- `attachment_text`: a text rendering (OCR, transcript, caption) of each file, so audio and PDFs can be counted against the budget. FK to the attachment.
- `memory_note`: one thing learned about the user, extracted by the application from messages. `memory_note_source` holds the FK to every message it came from.
- `memory_note_importance`: the ranking judgement, in its own table so it can be rescored without re-extracting. Contradicted or stale notes are handled by scoring them low, not by editing or deleting them.

Rebuild goes upward only: truncate `memory_note_importance` and rescore; or truncate `memory_note*` and re-extract from `user_message`.

## Building the 8,000-token context

Per invocation the application takes the current message, the `attachment_text` of its files, then `memory_note` rows for the user ordered by `importance DESC`, adding notes until `sum(token_count)` would exceed the remaining budget. Recency is the scorer's concern, not the schema's. What was actually sent is not recorded: it is not required, and at 8,000 tokens (~32 KB) times 2.5 billion invocations it would be ~80 TB.

## Streaming and Stop

One reply row per invocation, written when generation halts, not one row per streamed chunk: 100,000 users × 50,000 messages is 5 billion messages, roughly 2.5 billion replies; at ~50 chunks each that would be 125 billion rows. The in-flight text lives in the generation process until the halt; a crash mid-generation loses it, which the requirements do not cover.

## Erasure

Recording the request as a row lets execution be asynchronous and retried. The worker deletes each `attachment.storage_key` object, then `DELETE FROM app_user`, and `ON DELETE CASCADE` on every table removes the rest, the request row included. This is the one deletion the raw layer allows, and it is at the user's instruction, not because of any derivation.

## Sizes

- `user_message`: ~2.5 billion rows; at ~600 bytes each, ~1.5 TB.
- `assistant_reply`: ~2.5 billion rows; at ~2 KB each, ~5 TB.
- `attachment` and object-store volume: unknown (no rate given).
- `memory_note`: unknown; depends on the extractor's yield per message.
- Per-user memory selection is one index scan on `memory_note (user_id)` plus a join; notes per user unknown.

Partitioning by `hash(user_id)` is the natural cut if the tables above need it; whether they do is unknown, so the DDL starts flat.

## Deliberately absent

No model name, error states, retries, conversation grouping, note versioning, per-invocation record of which notes were used (raw referencing derived would break rebuilds), or user profile fields. None is in the requirements.
