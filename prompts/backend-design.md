# Backend design

Drop this into CLAUDE.md, .cursorrules, or a system prompt. Apply it to every backend service and every schema, type, and data shape in it: what the service records, where code goes, what code may call, and what it may know.

## Build what is asked for

1. Model only the requirements stated now. Do not add tables, columns, parameters, or abstractions for requirements you imagine coming later.

## Facts first, structure second

2. Design in this order: first list the raw facts the system will record, then derive structure from them. Do not start from the structure.
3. Any claim about speed, size, or cost carries a number or the word "unknown".
4. For every table or type, state the single kind of thing it records and who owns it. For every column or field, state whether it is a fact, a reference, or a derived value.

## Names mean one thing

5. A name carries only the one kind of thing it was created for. When the domain changes, create a new name. Never widen an existing one with flags or extra meanings.
6. A judgement an actor made (a user set the priority, a reviewer approved) is a fact: record who, what, and when. A judgement the system computed (scores, categories, labels, relevance, sentiment) is never source of truth: store it only as a derived value that can be dropped and recomputed. Showing a computed value to someone, or deciding something with it (sending a generated reply, blocking a payment on a score), is a fact: record the event raw, with the exact value, references to its inputs, and the model or version that produced it. Recomputing later may give a different answer.
7. Store what happened; derive what state it implies. Treat every closed set (enum, status column) as a claim that will turn out wrong, and prefer events over status. The stated requirement wins: when it asks only for current state, a status column is what was asked for; when it asks who changed it, when, or why, record events and derive the status.

## Keep raw and derived apart

8. Every derived record stores the keys of the raw records it came from, as fields a lookup can follow, never as a comment: one key, a list of keys, or the range that covers them (a period, a stream offset range). If a raw record can change, also store the version it was derived from. Where the store can enforce the reference, as a foreign key does, let it.
9. Keep raw and derived in separate tables. Derivation never updates or deletes anything in a raw table. Raw records of events are append-only; when the requirement asks only for current state, the raw record holding it may be updated in place.
10. Every derived table can be dropped and rebuilt entirely from the tables it was derived from. Derivation runs one way, from raw toward derived: never derive a table from one that was derived from it.
11. Never delete or compress raw records because a derivation of them exists.

## Three layers, nothing else

12. A backend's code has exactly three layers: core, operations, workflows. Do not add a fourth and do not rename these.
13. Core talks to infrastructure and knows nothing about the business. It knows the schema, but every business value (a threshold, a time window, which statuses count) arrives as a parameter: selecting invoices due before a date is core; deciding which date makes an invoice overdue is the operation's job. One function does one atomic thing: run one query, call one endpoint, read one cache key, publish one event. It has no opinion about why it is called.
14. Operations compose core calls into one business action with one name: upsert a user, load a conversation with its context, call provider A and then provider B with its answer. Business rules and domain validation are applied here, and transactions live here.
15. Workflows sequence operations into one complete use case. For one chat turn: load context, generate the reply, save both messages, update the profile. They decide order, branching, and what happens on failure. They contain no infrastructure calls and no rules about what a record may contain; those belong to operations.
16. Core functions are named after what they do to the infrastructure (insert row, post request, get key). Operations and workflows are named after the business action (save exchange, handle turn). If a name does not fit its layer's vocabulary, the code is in the wrong layer.

## Calls go one way, one step

17. Each layer calls only the layer directly beneath it. Workflows call operations. Operations call core. Core calls infrastructure. A workflow never touches core, even for a single read. A pass-through operation that does nothing but call one core function is legitimate and may be a one-line alias.
18. No sibling calls. An operation does not call another operation; a workflow does not call another workflow. Shared logic is pushed down a layer, never reused sideways: a shared pure rule becomes a helper, a shared read is done once by the workflow and passed down, and two actions that must happen together are one operation that repeats the core calls it needs.
19. Core raises typed infrastructure errors (not found, timeout, conflict). Operations decide what each one means for the business. Workflows decide whether to retry, compensate, or fail the use case. Anything that can run twice must be safe to repeat: an operation a workflow retries, and any workflow a queue consumer calls, since queues redeliver. Safe to repeat means every side effect is keyed, by a unique natural key in the database or an idempotency key sent to the provider, so a second run changes nothing.
20. A transaction begins and ends inside one operation, in a transaction scope that core provides; every core call made inside it shares the transaction. If two actions must succeed or fail together, they are one operation, not two operations wrapped by a workflow. That only works within one database: to pair a write with a publish, write the event to an outbox table in the same transaction and let a job publish it. Never keep a transaction open across a call to another service.

## Entry points translate, then delegate

21. HTTP handlers, queue consumers, cron jobs, and CLI commands are entry points, not a layer. Each one parses and validates the transport's input, builds a typed request, calls one workflow, and maps the result or error back into the transport's vocabulary: status code, ack or nack, exit code.
22. Entry points never import operations or core. The same workflow must run unchanged from HTTP, a queue, a CLI, and a unit test. A unit test of a workflow mocks the operations it imports; a test of an operation gives core a fake client. The code under test is never changed for the test.
23. Middleware is entry-point code: authentication, request IDs, rate limits, logging. When it needs I/O, such as resolving a session token, it calls a workflow. Authorization, whether this caller may do this thing, is a business rule and belongs in an operation.

## Helpers are pure, types are data

24. A helper is a pure function: no I/O, no clock, no randomness, no environment reads, no imports from any layer. Group helpers by subject (text, money, dates), never under utils, helpers, or common.
25. A helper that needs I/O is core. A helper that knows the domain is still a helper if it is pure: it lives in lib under its domain subject (pricing, eligibility), may be used by any number of operations, and imports only types. Business values (retry limits, minimum inputs, plan quotas) live in lib too: named constants under their subject, each defined once. Time and randomness are infrastructure and enter through core.
26. Domain shapes, request and response shapes, and error types live in one types module with no behaviour. Every layer imports it; it imports nothing from the project. Never import a layer just to reach a type. A declarative validation schema counts as a type if it declares only shape and format; business rules stay out of it.

## Wire once

27. Layers are joined by ordinary imports: workflows import operations, operations import core, entry points import workflows. An import linter enforces that each layer imports only the layer beneath it, types, and lib. One composition root reads config, builds the database pool, HTTP clients, and queue connections, hands them into core as module state set once at startup, and starts the entry points. It is the only file that reads environment variables and the only file that may import all three layers. Config is what differs between deployments: connection details, pool sizes, timeouts, and resource names that vary by environment. It goes into core with the clients. Nothing else is config: a table name that is the same everywhere is schema, and a business value is a lib constant. Logging, metrics, and tracing are exempt from the layer rules: the composition root configures them, and any layer may emit them directly.

## Placing new code

28. To place a piece of code, ask in order: does it talk to infrastructure (core)? Does it call core under one business name (operation)? Does it sequence business actions into a use case (workflow)? Does it translate a transport (entry point)? If none of these, it must be pure, and it goes in lib or types.
29. Data work is placed the same way. Writing a raw or derived record is an operation. Rebuilding a derived table from its sources is a workflow. A derivation rule that needs no I/O is a helper.

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
  lib/            pure helpers and business constants, grouped by subject
```
