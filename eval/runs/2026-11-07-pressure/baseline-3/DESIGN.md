# Design rationale

## Core model

There are no conversations, so `messages` is one ordered stream per user, keyed `(user_id, id)` with a global monotonic id. `role` distinguishes user and assistant turns. Everything else hangs off `users` with cascading foreign keys.

## Scale

100,000 users x 50,000 messages is ~5 billion rows. Every read and write is scoped to one user, so `messages`, `generations` and `message_files` are hash-partitioned by `user_id` (64 partitions). A user's whole history lives in one partition, which keeps "last N messages" and erasure local. Foreign keys that point at partitioned tables carry `user_id` so they can target the partition key and double as a cross-user consistency check. `files` and `memories` are orders of magnitude smaller and stay unpartitioned.

## Long-term memory and context selection

`memories` holds extracted, self-contained statements (facts, preferences, goals, summaries) rather than raw chat. Each row stores `importance` (0-100, assigned by the extraction step), `token_count`, and recall statistics. `select_memories_for_context(user_id, budget)` orders active memories by importance, then by last recall, and uses a running token sum to fill the budget; the partial index `memories_select_idx` serves that query directly. Prompt assembly is: system prompt, selected memories, then the most recent messages (by `token_count`) until 8,000 tokens are used.

Old messages do not vanish from memory: a consolidation job condenses them into `kind = 'summary'` memories and advances `users.summarized_through_message_id`. Corrections are modelled with `superseded_by_id` instead of overwriting, so the assistant can also be told "you previously believed X".

Each `generations` row records `context_memory_ids`, giving an audit trail of what the model saw and the data to update `recall_count` / `last_recalled_at`, which later feeds importance adjustment.

## Streaming and Stop

An invocation inserts the assistant `messages` row with `status = 'generating'` and a `generations` row before calling the model. Chunks stream to the client and are flushed to `content` periodically. Pressing Stop sets `generations.stop_requested_at` (and may `NOTIFY` the worker); the worker halts, writes the partial text, and marks the message `stopped` with `finish_reason = 'stopped_by_user'`. The partial reply is therefore an ordinary message that persists and is shown in history. `generations_running_idx` lets crash recovery find orphaned runs.

## Files

`files` stores metadata and an object-storage key; bytes never enter PostgreSQL. Uploads happen before the message is sent, so files are linked through `message_files` rather than a column on `files`. The link's `relation` covers both cases in the requirements: `attachment` (sent with a user message) and `reference` (an assistant reply pointing at a file). `extracted_text`, `caption` and `text_token_count` let the model use PDFs, documents, transcripts and images within the token budget without resending the original.

## Erasure

A request inserts an `erasure_requests` row and sets `users.erasure_requested_at`, locking the account. A worker deletes every object listed in `files.storage_key`, then `DELETE FROM users`, which cascades through all per-user tables in one transaction. `erasure_requests` deliberately has no foreign key and no personal data, so proof of erasure survives the user.

## Possible extensions

Add a `vector` column (pgvector) on `memories` for similarity recall alongside importance, and a `tsvector` on `messages` for search. Neither changes the structure above.
