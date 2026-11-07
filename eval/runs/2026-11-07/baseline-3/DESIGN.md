# Design rationale

## No sessions, one timeline

Because there is no conversation concept, `messages` is a single append-only timeline per user, ordered by id. `invocations` records each LLM call as a point on that timeline rather than as a container for messages. Every invocation stores which profile version, which timeline summary, and which memory items (`invocation_memory_uses`, `context_window`) were actually sent, so any past answer can be audited or replayed.

## Three layers of memory

A unified context cannot literally hold a user's entire history, so memory is split by granularity:

1. **Recent messages**, read directly from `messages`.
2. **`timeline_summaries`**: rolling compaction of older messages. Each row covers a contiguous id range and may supersede a previous summary, so the newest row for a user is always the one injected.
3. **`memory_items`**: discrete facts, preferences, goals, and standing instructions. These are the durable "what we know about this user" and survive indefinitely. Items are immutable; corrections insert a new row and set `superseded_by_id`/`retired_at` on the old one, preserving provenance via `source_message_id`.

`profile_versions` is a derived, versioned prose synthesis of active memory items that is cheap to prepend to every prompt. Versioning it (rather than a mutable column on `users`) lets invocations reference exactly what the model saw.

## Retrieval

`memory_items.embedding` (pgvector, HNSW cosine index) supports semantic recall when the active set exceeds the token budget; `importance` and `last_recalled_at`/`recall_count` give deterministic tie-breaking and decay signals. A partial index on active items keeps the common query fast.

## Postgres specifics

Identity columns, `TIMESTAMPTZ`, `CHECK`-constrained enumerations (easier to evolve than enum types), `JSONB` only for genuinely schemaless payloads, and `ON DELETE CASCADE` from `users` so account deletion removes all memory. Circular FKs between `invocations` and the summary/profile tables are added after both tables exist.
