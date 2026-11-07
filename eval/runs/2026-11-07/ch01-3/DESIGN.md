# Design

## Raw facts first

The system records seven kinds of event. Each gets exactly one table, named for that kind and nothing else:

1. an account exists (`app_user`)
2. a user sent text (`user_message`)
3. the model was called because of that text (`llm_invocation`)
4. the call returned text (`assistant_message`)
5. during a call the assistant stated something about the user worth remembering (`memory_note`)
6. during a call the assistant stated that a note no longer holds (`memory_note_retraction`)
7. a call was given a note as input (`invocation_memory_input`)

Every table comment states the fact it records and who owns it. Column kinds follow one convention stated at the top of `schema.sql`: `*_id` columns are references, everything else is a fact, and no raw table holds a derived column.

All raw tables are append-only, enforced by a trigger rather than by convention. Composite foreign keys on `(id, user_id)` make it impossible for a note, retraction, or invocation to be attached to a different user's rows.

## Derived layer

"What the assistant currently knows about a user" is a derived state: a note minus its retraction. It lives in the `current_memory` view, not in a status column. A correction is two events (new note, retraction of the old one), both tied by foreign key to the invocation that made them. `invocation_memory_input` records exactly what any past call saw, so memory is auditable after the fact.

Both derived objects are views: they store nothing, cost nothing to rebuild, and cannot drift from the raw layer.

## Deliberately absent

No session or conversation table; the requirements have none. No `message` table with a role flag; user and assistant messages are different kinds of fact and get different tables. No embeddings, retrieval ranking, token counts, failure records, or profile fields; none is stated.

## Scale

Unknown. `current_memory` is an anti-join over `memory_note` indexed by `(user_id, asserted_at)`; its cost grows with notes per user, a number not yet known. If measurement shows a problem, materialize the view into a table keyed by `note_id`. It remains rebuildable from the raw layer.
