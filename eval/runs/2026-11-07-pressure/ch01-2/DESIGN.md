# Design

## Raw facts first

What the system actually observes, in order of occurrence:

1. An account was created.
2. The user sent a text, possibly with files (bytes go to object storage).
3. A generation was started for that text, against a named model.
4. The user pressed Stop (zero or more times).
5. The stream closed, having produced some text, with the provider's finish reason or an error.
6. The user asked for erasure.

Everything else (the "working" indicator, the reply, memory, importance) is derived from these six.

## Layers

Raw tables are append-only: `app_user`, `user_message`, `user_file`, `generation`, `stop_press`, `generation_end`, `erasure_request`. There are no status columns. A generation is "working" iff it has no `generation_end` row (view `generation_open`); it was stopped iff a `stop_press` row exists; erasure is complete iff the `app_user` row is gone.

Derived tables carry a foreign key to their source and can be truncated and rebuilt upward: `memory_note` from `generation` (the exchange: message, files, produced text), `memory_importance` from `memory_note`. Each carries an `extractor`/`scorer` version so a rebuild is comparable to what it replaces. The views `assistant_reply` and `generation_open` are derivations with zero storage.

## Memory and the 8,000-token budget

"Unified memory" is two things: the verbatim exchange history and the notes the extractor draws from it. Per invocation the builder spends the budget in order: the new message and its files; notes in `memory_importance.score` order; recent exchanges newest-first; stop when the budget is spent. The notes/history split is application policy, not schema. Tokens are counted at build time over at most ~32 KB of text (8,000 tokens x ~4 bytes), so no token counts are stored.

Importance is a judgement. It lives only in `memory_importance`, keyed by note; `DELETE FROM memory_importance` followed by a scorer run loses nothing.

## Stop

Streaming reaches the client over a live channel, not through the database. On Stop, a `stop_press` row is inserted, the worker cancels the provider stream and writes `generation_end` with the text produced so far; `provider_finish_reason` is NULL. The partial text is kept and shown like any reply.

Per-chunk rows were rejected: 2.5 x 10^9 replies x k chunks (k unknown, likely 10-50) is 2.5-12.5 x 10^10 rows, bought only for a worker crash mid-stream, which the requirements do not name.

## Files

`user_file` records one upload per row, bound to the message it arrived with; bytes live in object storage under `storage_key`. Replies refer to files in their text. No derived file text (OCR, transcript, caption) is modelled because none is required.

## Erasure

`erasure_request` is the fact. Fulfilment: delete every object `storage_key` belonging to the user, then `DELETE FROM app_user WHERE id = $1`. Every row owned by a user reaches `app_user` through `ON DELETE CASCADE`, so raw and derived vanish together and no derived row can outlive its source. The request row keeps only the opaque id and time; drop it too if policy counts that as personal data. This is the single delete path; derivation never deletes.

## Numbers

- 10^5 users x 5 x 10^4 messages = 5 x 10^9 messages: 2.5 x 10^9 `user_message`, 2.5 x 10^9 `generation` and `generation_end` (one reply per message assumed).
- Text volume: average sizes unknown; at 300 B per user message and 1.2 KB per reply, 0.75 TB + 3 TB.
- `user_message (user_id, received_at)` index: 2.5 x 10^9 x ~40 B = ~100 GB.
- Notes per user: unknown; upper bound one per exchange, 2.5 x 10^4. `memory_importance (user_id, score DESC)` makes the ranked walk an index range scan.
- Erasure of one user: ~10^5 raw rows plus notes; seconds, exact time unknown.
- Hash partitioning by `user_id` is not in the DDL. Every per-user table is keyed to allow it once measured size demands it (threshold unknown).

## Not modelled

Login and profile, conversations, retries, message editing, memory supersession, token accounting, file-content extraction. None is stated; each gets its own table when it is.
