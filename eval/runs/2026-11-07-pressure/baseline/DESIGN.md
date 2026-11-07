# Design rationale

## Shape

Seven tables: `users`, `messages`, `files`, `file_derivations`, `message_files`, `memories`, `memory_sources`, plus an `erasure_requests` audit log. Every table carries `user_id` and cascades from `users`, so the data of one account is a single connected graph with one root.

## No sessions, one stream

`messages` is a single ordered stream per user, keyed `(user_id, id)` with a global bigint sequence. There is no conversation table because the requirements have no such concept; the "context" of an invocation is assembled at call time, not stored as a container.

## Invocation = assistant message

An LLM invocation produces exactly one reply, so generation metadata (`model`, `prompt_tokens`, `status`, `stop_requested_at`, `error`) lives on the assistant's row rather than in a separate invocations table. At 2.5 billion invocations a second table would double the largest dataset for no gain. A CHECK keeps those columns NULL on user messages.

## Stop

The worker inserts the assistant row with `status = 'generating'` and flushes streamed text into `content` periodically. Pressing Stop is `UPDATE ... SET stop_requested_at = now()`; the worker sees it on its next flush, writes the final partial text, and sets `status = 'stopped'` with `completed_at`. Partial output is simply what is in `content`. A partial unique index on `(user_id) WHERE status = 'generating'` enforces one reply in flight per user and makes the "assistant is working" check an index-only lookup.

## Memory and the 8k budget

Raw messages are never the long-term memory: at 50,000 messages per user they cannot be. `memories` holds distilled facts, preferences and rolling span summaries, each with an extractor-assigned `importance` in [0, 1] and a cached `token_count`. The packer runs one query against `memories_select_idx` (`user_id, importance DESC, last_used_at DESC`, active only) and takes rows while the running sum of `token_count` stays under the budget left after the system prompt, the newest messages and any attached file text. More important memories therefore always win when space is short; `last_used_at` breaks ties and lets the extractor decay memories that are never useful. `use_count` and `context_memory_ids` give the feedback loop and the audit trail. Stale facts are marked `superseded` and point at their replacement rather than being deleted, so provenance survives. A generated `tsvector` with a GIN index gives lexical relevance to the current prompt; a pgvector column could be added beside it without changing the model.

Summaries record the message span they cover, so the packer can treat "everything before message N" as covered by summaries and include only verbatim messages after it.

## Files

`files` is metadata; bytes live in object storage under `storage_key`. `file_derivations` holds what the model actually consumes: PDF text, audio transcripts, image captions, each with a `token_count`. `message_files` links files to any message, including assistant replies that refer to them, and its composite foreign keys guarantee the file and the message belong to the same user.

## Scale

`messages` is hash-partitioned on `user_id` into 64 partitions (~80 M rows each) to keep vacuum, index size and bloat manageable. All per-user reads hit one partition and one index. Other tables are one to two orders of magnitude smaller and stay unpartitioned.

## Erasure

`users.status = 'erasing'` blocks new invocations. A job deletes every `storage_key` from object storage, records `blobs_purged_at`, then issues `DELETE FROM users WHERE id = ?`; cascades remove everything else. `erasure_requests` has no foreign key and holds only the id and timestamps, so it survives as proof of completion without retaining personal data.
