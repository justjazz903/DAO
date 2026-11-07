# Design

## Raw facts first

The system records exactly five kinds of event: a user exists; a user sent text; the application sent a request to the LLM; the LLM replied; the LLM did not reply. Each is one append-only table in schema `raw`, enforced by a trigger that rejects UPDATE and DELETE. There is no session or conversation table because the requirement says there is no such concept; ordering comes from `sent_at` and foreign keys.

Reply and failure are separate tables rather than a nullable `response`/`error` pair or a status column. Each table records one kind of thing; what "state" an invocation is in is derived by joining.

`llm_invocations.request` stores the literal request body, including whatever memory text was included. This makes every invocation auditable without raw rows pointing at derived rows.

## Memory is derived

What the assistant "learns" is a judgement produced by a model, so it lives in schema `derived`, not `raw`. `memory_items` rows each carry a foreign key to the `raw.user_messages` row they were extracted from. The read path for an invocation is: load all `memory_items` for the user, place `content` into the request. Nothing else is needed for "available to every future invocation".

Rebuild: `TRUNCATE derived.memory_items`, re-run extraction over `raw.user_messages` ordered by `sent_at`. Because extraction is an LLM call, a rebuild reproduces the same evidence links but may reword `content`; `extractor_model` and `extracted_at` make generations distinguishable.

## Deliberately absent

- Supersession or contradiction between memory items. Resolving "I moved to Paris" against "I live in Berlin" is a judgement; it belongs in the extraction step or at read time, not as a column.
- Embeddings, retrieval ranking, token usage, extraction-run logging, user profile fields. None are stated requirements.

## Scale

Message volume per user and memory items per user: unknown. One composite index per read path (`user_id, sent_at` and `user_id, extracted_at`) is the only performance provision made.
