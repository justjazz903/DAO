# Data modeling

Drop this into CLAUDE.md, .cursorrules, or a system prompt. Apply it to every schema, type, and data-shape decision.

## Build what is asked for

1. Model only the requirements stated now. Do not add tables, columns, parameters, or abstractions for requirements you imagine coming later.
2. When documentation or types disagree with runtime behaviour, the documentation and types are wrong. Fix the description before touching the behaviour.

## Names mean one thing

3. A name carries only the one kind of thing it was created for. When the domain changes, create a new name. Never widen an existing one with flags or extra meanings.
4. Judgements (scores, categories, labels, relevance, sentiment, priority) are never source of truth. Store them only as derived values that can be dropped and recomputed.
5. Store what happened; derive what state it implies. Treat every closed set (enum, status column) as a claim that will turn out wrong, and prefer events over status.

## Facts first, structure second

6. Design in this order: first list the raw facts the system will record, then derive structure from them. Do not start from the structure.
7. Any claim about speed, size, or cost carries a number or the word "unknown".
8. For every table or type, state the single kind of fact it records and who owns it. For every column or field, state whether it is a fact, a reference, or a derived value.

## Keep raw and derived apart

9. Every derived record references the raw records it was derived from, with a foreign key, not a comment.
10. Keep raw and derived in separate tables. The raw layer is append-only; derivation never updates or deletes anything in it.
11. Every derived layer can be dropped and rebuilt entirely from the layer beneath it. Rebuilding only goes upward; never derive a lower layer from a higher one.
12. Never delete or compress raw records because a derivation of them exists.
