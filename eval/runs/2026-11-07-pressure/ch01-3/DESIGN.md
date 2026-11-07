# Design

## Raw facts first

Before any structure, the things the system will actually record:

1. A user exists.
2. A user sent a text at a time.
3. That text carried zero or more files (bytes, name, type, size).
4. Generation of a reply to that text started.
5. The user pressed Stop on a reply.
6. Generation of a reply ended, having produced some text.
7. A user asked for everything to be erased.

Each is one table in the RAW section, append-only, owned by whoever caused it. Nothing in the raw layer is ever updated; there is no status column anywhere.

## Working, Stop, and the kept partial

`reply` records the start. `reply_end` records the halt plus whatever text existed at that moment. `reply_stop` records the user's act. State is derived from which rows exist: no `reply_end` means "working"; `reply_end` with a `reply_stop` means "cut short, partial text shown"; `reply_end` alone means "finished". No enum has to be extended when a new way of ending appears.

## Memory and the 8,000-token budget

The requirement is that what the assistant learns persists and is available to every future invocation. "Learning" is a derivation: an extractor reads one exchange (`user_message` + `reply_end`) and writes zero or more `memory_note` rows, each keyed to its source exchange. Notes are never updated; a changed fact arrives as a newer note from a later exchange, and rebuilding is `TRUNCATE memory_note` followed by re-extraction over all exchanges. The extractor is an LLM, so a rebuild is equivalent in kind, not byte-identical.

Importance is a judgement, so it lives in its own table, `memory_note_importance`, keyed to the note. It can be truncated and rescored without touching anything beneath it. Context assembly for one invocation is: the current message and its attachments, then notes for that user ordered by score descending, taking rows while the running sum of `token_count` stays under 8,000. One query against `memory_note (user_id)` joined to the score table.

Files are passed to the model directly from object storage during the invocation that carries them; what the model learned from a file reaches later invocations as memory notes, like any other content. The database holds only `storage_key`, name, type, and size.

## Erasure

`erasure_request` records the request. Fulfilment deletes the objects behind `attachment.storage_key`, then `DELETE FROM app_user`; every table cascades from the user, including the request row itself. This is the one deletion in the system, and it is caused by the user, not by the existence of a derivation.

## Numbers

- 100,000 users x 50,000 messages = 5e9 messages, split roughly 2.5e9 `user_message` and 2.5e9 `reply` / `reply_end` rows.
- `user_message_user_sent` index: about 32 bytes per entry, roughly 80 GB at full scale.
- Notes per user: unknown. Context-assembly latency: unknown until notes per user is measured. If it exceeds budget, the fix is a composite index on the score table carrying `user_id`, not a schema change.
- Attachment bytes per user: unknown; this is why bytes are kept out of PostgreSQL.
- Partitioning `user_message` by `hash(user_id)` is the expected step once the table passes 1e9 rows; it changes DDL, not the model.

## Deliberately not modelled

Authentication fields, model names, generation failures, retries, file reuse across messages, and token counts of messages themselves. None is stated; each gets its own table when it is.
