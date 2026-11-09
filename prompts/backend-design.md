# Backend design

Drop this into CLAUDE.md, .cursorrules, or a system prompt. Apply it to every backend service and every schema, type, and data shape in it: what the service records, where code goes, what code may call, and what it may know.

## Build what is asked for

1. Model only the requirements stated now. Do not add tables, columns, parameters, or abstractions for requirements you imagine coming later.
2. When documentation or types disagree with runtime behaviour, the documentation and types are wrong. Fix the description before touching the behaviour.

## Facts first, structure second

3. Design in this order: first list the raw facts the system will record, then derive structure from them. Do not start from the structure.
4. Any claim about speed, size, or cost carries a number or the word "unknown".
5. For every table or type, state the single kind of fact it records and who owns it. For every column or field, state whether it is a fact, a reference, or a derived value.

## Names mean one thing

6. A name carries only the one kind of thing it was created for. When the domain changes, create a new name. Never widen an existing one with flags or extra meanings.
7. A judgement an actor made (a user set the priority, a reviewer approved) is a fact: record who, what, and when. A judgement the system computed (scores, categories, labels, relevance, sentiment) is never source of truth: store it only as a derived value that can be dropped and recomputed.
8. Store what happened; derive what state it implies. Treat every closed set (enum, status column) as a claim that will turn out wrong, and prefer events over status. The stated requirement wins: when it asks only for current state, a status column is what was asked for; when it asks who changed it, when, or why, record events and derive the status.

## Keep raw and derived apart

9. Every derived record references the raw records it was derived from, with a foreign key, not a comment.
10. Keep raw and derived in separate tables. The raw layer is append-only; derivation never updates or deletes anything in it.
11. Every derived layer can be dropped and rebuilt entirely from the layer beneath it. Rebuilding only goes upward; never derive a lower layer from a higher one.
12. Never delete or compress raw records because a derivation of them exists.

## Three layers, nothing else

13. A backend's code has exactly three layers: core, operations, workflows. Do not add a fourth and do not rename these.
14. Core talks to infrastructure and knows nothing about the business. One function does one atomic thing: run one query, call one endpoint, read one cache key, publish one event. It has no opinion about why it is called.
15. Operations compose core calls into one business action with one name: upsert a user, load a conversation with its context, call provider A and then provider B with its answer. Business rules, domain validation, and transactions live here.
16. Workflows sequence operations into one complete use case. For one chat turn: load context, generate the reply, save both messages, update the profile. They decide order, branching, and what happens on failure. They contain no infrastructure calls and no rules about what a record may contain; those belong to operations.
17. Core functions are named after what they do to the infrastructure (insert row, post request, get key). Operations and workflows are named after the business action (save exchange, handle turn). If a name does not fit its layer's vocabulary, the code is in the wrong layer.

## Calls go one way, one step

18. Each layer calls only the layer directly beneath it. Workflows call operations. Operations call core. Core calls infrastructure. A workflow never touches core, even for a single read. A pass-through operation that does nothing but call one core function is legitimate, may be a one-line alias, and is where the business rule will go when it arrives.
19. No sibling calls. An operation does not call another operation; a workflow does not call another workflow. Shared logic is pushed down a layer, never reused sideways: a shared pure rule becomes a helper, a shared read is done once by the workflow and passed down, and two actions that must happen together are one operation that repeats the core calls it needs.
20. Core raises typed infrastructure errors (not found, timeout, conflict). Operations decide what each one means for the business. Workflows decide whether to retry, compensate, or fail the use case.
21. A transaction begins and ends inside one operation. If two actions must succeed or fail together, they are one operation, not two operations wrapped by a workflow.

## Entry points translate, then delegate

22. HTTP handlers, queue consumers, cron jobs, and CLI commands are entry points, not a layer. Each one parses and validates the transport's input, builds a typed request, calls one workflow, and maps the result or error back into the transport's vocabulary: status code, ack or nack, exit code.
23. Entry points never import operations or core. The same workflow must run unchanged from HTTP, a queue, a CLI, and a unit test. A unit test of a workflow mocks the operations it imports; a test of an operation gives core a fake client. The code under test is never changed for the test.
24. Middleware is entry-point code: authentication, request IDs, rate limits, logging. When it needs I/O, such as resolving a session token, it calls a workflow. Authorization, whether this caller may do this thing, is a business rule and belongs in an operation.

## Helpers are pure, types are data

25. A helper is a pure function: no I/O, no clock, no randomness, no environment reads, no imports from any layer. Group helpers by subject (text, money, dates), never under utils, helpers, or common.
26. A helper that needs I/O is core. A helper that knows the domain is still a helper if it is pure: it lives in lib under its domain subject (pricing, eligibility), may be used by any number of operations, and imports only types. Time and randomness are infrastructure and enter through core.
27. Domain shapes and request and response shapes live in one types module with no behaviour. Every layer imports it; it imports nothing. Never import a layer just to reach a type.

## Wire once

28. Layers are joined by ordinary imports: workflows import operations, operations import core, entry points import workflows. An import linter enforces that each layer imports only the layer beneath it, types, and lib. One composition root reads config, builds the database pool, HTTP clients, and queue connections, hands them into core as module state set once at startup, and starts the entry points. It is the only file that reads environment variables and the only file that may import all three layers.

## Placing new code

29. To place a piece of code, ask in order: does it talk to infrastructure (core)? Does it apply a business rule or group several core calls under one business name (operation)? Does it sequence business actions into a use case (workflow)? Does it translate a transport (entry point)? If none of these, it must be pure, and it is a helper or a type.
30. Data work is placed the same way. Appending a raw record or writing a derived record is an operation. Rebuilding a derived data layer from the layer beneath it is a workflow. A derivation rule that needs no I/O is a helper.

A layout that satisfies every rule above:

```
src/
  main            composition root
  entry/
    http/         handlers and middleware
    queue/        consumers
    cron/         jobs
  workflows/
  operations/
  core/
  types/          data shapes, no logic
  lib/            pure helpers, grouped by subject
```
