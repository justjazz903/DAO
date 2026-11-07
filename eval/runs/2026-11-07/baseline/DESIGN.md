# Design rationale

## One stream, not sessions

Because every invocation shares a single long-term context, `messages` has no conversation key: each row belongs directly to a user and is ordered by `seq`, an identity column that gives a stable total order per user. A per-user history is therefore just `WHERE user_id = ? ORDER BY seq`.

## Three tiers of memory

A single unbounded stream cannot be sent to the model whole, so the schema separates memory by how it is used when a prompt is assembled:

1. **Recent raw messages** (`messages`): the tail of the stream, included verbatim.
2. **Compacted history** (`history_summaries`): each row summarizes an inclusive `seq` range and stands in for those messages in the prompt. This keeps older context available without storing a second copy.
3. **Distilled facts** (`memories`): atomic natural-language statements the assistant has learned, retrieved by hybrid search (pgvector `embedding` plus a generated `tsvector`), weighted by `importance`, `confidence` and recency (`last_accessed_at`). `pinned` memories bypass retrieval entirely. `user_profile` holds a handful of deterministic key/value attributes (name, language) that are read on every call without retrieval.

Memories are never updated in place when a fact changes; the old row is marked `superseded` and points to its replacement via `superseded_by`. This preserves an auditable history and lets the assistant reason about change over time. `memory_sources` records which messages a memory was derived from, so provenance is queryable and memories can be re-derived or deleted if a source message is removed.

## Reproducibility

`llm_invocations` stores a `context_manifest` listing the exact message, summary and memory ids assembled into each prompt. Together with the immutable message stream this makes any past response reproducible and debuggable.

## PostgreSQL choices

UUID keys, `timestamptz` everywhere, enums for closed vocabularies, `ON DELETE CASCADE` from `users` so account deletion removes all derived data, and partial/HNSW/GIN indexes aimed at the retrieval queries that run on every invocation.
