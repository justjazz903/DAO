# Design rationale

**Shape.** There are no conversations, so `messages` hangs directly off `users` as one append-only timeline per user. Every table holding user data carries `user_id` and cascades from `users`, which makes erasure a single `DELETE FROM users`.

**Scale.** 100k users x 50k messages is 5 billion rows. `messages` is hash-partitioned on `user_id` (64 partitions), so one user's history lives in one partition and the primary key `(user_id, id)` alone serves every access path: latest-N (backward index scan), reply lookup, attachment joins. Ids come from one global sequence, so ordering by `id` is creation order and no timestamp index is needed. File bytes live in object storage; Postgres holds metadata and extracted text only.

**Memory.** Two layers, both with precomputed `token_count` so selection is pure SQL:

1. `user_digest`: one short, always-included profile paragraph per user, rebuilt by the extractor.
2. `memories`: discrete facts, preferences, goals and events with `importance` (0-1, assigned at extraction), `use_count`, `last_used_at` and `valid_until`. Corrections never overwrite: a new row supersedes the old (`superseded_by`, `is_active = false`), keeping history while the partial index on active rows stays small.

Assembling an 8,000-token context: system prompt and digest first; then memories chosen by a running `SUM(token_count) OVER (ORDER BY score DESC)` where score is `importance`, boosted by recent use and decayed past `valid_until`; then the most recent messages (plus `extracted_text` of their files) filling the remainder, with output tokens reserved. Memories that were included get `use_count`/`last_used_at` bumped. `users.memory_cursor` lets the asynchronous extractor resume at the first unprocessed message.

**Generation and Stop.** When an invocation starts, an assistant row is inserted with `status = 'generating'` and empty content; a tiny partial index lets the client (or a reconnecting client) see that the assistant is working. Tokens stream to the client. On Stop the server writes the partial text with `status = 'stopped'`; on completion, `'completed'`. Stopped text stays in history and is extracted from like any other message. `model`, `prompt_tokens`, `completion_tokens` and `stop_reason` live on the same row: a separate invocations table would be a second multi-billion-row table in a 1:1 relationship.

**Files.** `files` is per user with a content hash for dedup and `extracted_text` (OCR, transcript, PDF text) so non-text attachments can enter the token budget. `message_files` links a file to any message with `link_kind`: `attached` for the user's upload, `referenced` when the assistant's reply refers to it, so "which file did it mean" is answerable and the client can render the reference. Uploads happen before the message is sent (`status = 'uploading'`); a sweeper removes files never linked to a message.

**Erasure.** `erasure_requests` deliberately has no foreign key so it survives the delete and records completion. `DELETE FROM users` cascades through every table; an AFTER DELETE trigger on `files` copies each `storage_key` into `blob_deletion_queue`, which a worker drains against object storage. The only thing that outlives the user is the request's opaque uuid. Backup retention is an operational policy outside the schema.

**Not included.** Vector embeddings (pgvector) would add relevance ranking on top of importance; a nullable column can be added to `memories` later without restructuring.
