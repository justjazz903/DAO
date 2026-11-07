# Design rationale

## No conversations, one transcript per user

`messages` is a single append-only log keyed by `user_id`, ordered by a global identity `seq`. There is no conversation table because the requirement rules it out; the "context" of a call is simply a window over the user's own log. `seq` rather than `created_at` defines order so retries and clock skew never reorder turns.

## Three layers of memory

Long-term memory must survive indefinitely while the prompt window cannot, so the schema separates:

1. **Episodic** – `messages.embedding` lets older turns that have scrolled out of the window be recalled semantically.
2. **Semantic** – `memories` holds discrete, self-contained facts extracted from the transcript. Each has a kind, confidence, importance, bitemporal validity (`valid_from`/`valid_until`), a `superseded_by_id` chain for corrections, and usage counters for decay. Nothing is overwritten; a partial index serves only live facts, keeping retrieval cheap as history grows.
3. **Narrative** – `memory_summaries` is a versioned, condensed profile folded forward from the transcript (`covers_through_seq`). The latest version is loaded verbatim into every call, guaranteeing baseline continuity even if vector retrieval misses.

Together these mean every invocation starts with the summary, a recent verbatim window, and the top-k semantically retrieved facts and turns.

## Invocations are first-class

`invocations` records each LLM call with the summary version and window start it used, plus token usage. `invocation_memories` logs which facts were injected and their similarity. This makes any answer reproducible and lets retrieval ranking be tuned from real data.

## PostgreSQL specifics

pgvector with HNSW indexes handles similarity search without a second store. Enums constrain roles and kinds; `jsonb` absorbs client-specific metadata. Soft deletes (`deleted_at`) on users and memories support "forget this" requests while preserving audit history; cascading FKs give clean hard deletion when legally required.
