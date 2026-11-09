# Backend design

Drop this into CLAUDE.md, .cursorrules, or a system prompt. Apply it to every backend service and every schema, type, and data shape in it: what the service records, where code goes, what code may call, and what it may know.

## Build what is asked for

1. Model only the requirements stated now. Do not add tables, columns, parameters, or abstractions for requirements you imagine coming later.

## Facts first, structure second

2. Design in this order: first list the raw facts the system will record, then derive structure from them. Do not start from the structure.
3. Any claim about speed, size, or cost carries a number or the word "unknown".

## Names mean one thing

4. A name carries one kind of thing; if one sentence cannot say what a table or type holds, split it. When the domain changes, a name may widen to new cases only if every field still means the same thing in every record; rename it if the old name fits only the old scope. Otherwise, create a new name. Never let a flag change what another field means.

## Keep raw and derived apart

5. A value is derived only if the exact same value can be recomputed from raw records, such as a total or a score computed by code. Store it as a derived value that can be dropped and rebuilt; it is never source of truth. Anything that cannot be recomputed exactly is a fact: a judgement a person made (a user set the priority, a reviewer approved), a model's output, a provider's answer. Record it raw with who or what produced it and when; for a model or provider, also the inputs it was given and its version.
6. Every derived record stores the keys of the raw records it came from, as fields a lookup can follow, never as a comment: one key, a list of keys, or the range that covers them (a period, a stream offset range). If a raw record can change, also store the version it was derived from. Where the store can enforce the reference, as a foreign key does, let it.
7. Keep raw and derived in separate tables. Derivation never updates or deletes anything in a raw table. Raw records of events are append-only; when the requirement asks only for current state, the raw record holding it may be updated in place.
8. Every derived table can be dropped and rebuilt entirely from the tables it was derived from. Derivation runs one way, from raw toward derived: never derive a table from one that was derived from it.
9. Never delete or compress raw records because a derivation of them exists.

## Three layers, nothing else

10. A backend's code has exactly three layers: core, operations, workflows. Do not add a fourth and do not rename these.
11. Core talks to infrastructure and knows nothing about the business. It knows the schema, but every business value (a threshold, a time window, which statuses count) arrives as a parameter: selecting invoices due before a date is core; deciding which date makes an invoice overdue is the operation's job. One function does one atomic thing: run one query, call one endpoint, read one cache key, publish one event. It has no opinion about why it is called.
12. Operations compose core calls into one business action with one name: upsert a user, load a conversation with its context, call provider A and then provider B with its answer. Business rules and domain validation are applied here, and transactions live here.
13. Workflows sequence operations into one complete use case. For one chat turn: load context, generate the reply, save both messages, update the profile. They decide order, branching, and what happens on failure. They contain no infrastructure calls and no rules about what a record may contain; those belong to operations.
14. Core functions are named after what they do to the infrastructure (insert row, post request, get key). Operations and workflows are named after the business action (save exchange, handle turn). If a name does not fit its layer's vocabulary, the code is in the wrong layer.

## Calls go one way, one step

15. Each layer calls only the layer directly beneath it. Workflows call operations. Operations call core. Core calls infrastructure. A workflow never touches core, even for a single read. A pass-through operation that does nothing but call one core function is legitimate and may be a one-line alias.
16. No sibling calls. An operation does not call another operation; a workflow does not call another workflow. Shared logic is pushed down a layer, never reused sideways: a shared pure rule becomes a helper, a shared read is done once by the workflow and passed down, and two actions that must happen together are one operation that repeats the core calls it needs.
17. Core raises typed infrastructure errors (not found, timeout, conflict). Operations decide what each one means for the business. Workflows decide whether to retry, compensate, or fail the use case. Anything that can run twice must be safe to repeat: an operation a workflow retries, and any workflow a queue consumer calls, since queues redeliver. Safe to repeat means every side effect is keyed, by a unique natural key in the database or an idempotency key sent to the provider, so a second run changes nothing.
18. A transaction begins and ends inside one operation, in a transaction scope that core provides; every core call made inside it shares the transaction. If two actions must succeed or fail together, they are one operation, not two operations wrapped by a workflow. That only works within one database: to pair a write with a publish, write the event to an outbox table in the same transaction and let a job publish it. Never keep a transaction open across a call to another service.
19. Behaviour that follows a state change is triggered by an event: the operation that makes the change also emits an event through the outbox, and a queue consumer starts the workflow that reacts. Never detect a state change by polling a column in a loop.

## Entry points translate, then delegate

20. HTTP handlers, queue consumers, cron jobs, and CLI commands are entry points, not a layer. Each one parses and validates the transport's input, builds a typed request, calls one workflow, and maps the result or error back into the transport's vocabulary: status code, ack or nack, exit code.
21. Entry points never import operations or core. The same workflow must run unchanged from HTTP, a queue, a CLI, and a unit test. A unit test of a workflow mocks the operations it imports; a test of an operation gives core a fake client. The code under test is never changed for the test.
22. Middleware is entry-point code: authentication, request IDs, rate limits, logging. When it needs I/O, such as resolving a session token, it calls a workflow. Authorization, whether this caller may do this thing, is a business rule and belongs in an operation.

## Helpers are pure, types are data

23. A helper is a pure function: no I/O, no clock, no randomness, no environment reads, no imports from any layer. Group helpers by subject (text, money, dates), never under utils, helpers, or common.
24. A helper that needs I/O is core. A helper that knows the domain is still a helper if it is pure: it lives in lib under its domain subject (pricing, eligibility), may be used by any number of operations, and imports only types. Business values (retry limits, minimum inputs, plan quotas) live in lib too: named constants under their subject, each defined once. Time and randomness are infrastructure and enter through core.
25. Domain shapes, request and response shapes, and error types live in one types module with no behaviour. Every layer imports it; it imports nothing from the project. Never import a layer just to reach a type. A declarative validation schema counts as a type if it declares only shape and format; business rules stay out of it.

## Wire once

26. Layers are joined by ordinary imports: workflows import operations, operations import core, entry points import workflows. An import linter enforces that each layer imports only the layer beneath it, types, and lib. One composition root reads config, builds the database pool, HTTP clients, and queue connections, hands them into core as module state set once at startup, and starts the entry points. It is the only file that reads environment variables and the only file that may import all three layers. Config is what differs between deployments: connection details, pool sizes, timeouts, and resource names that vary by environment. It goes into core with the clients. Nothing else is config: a table name that is the same everywhere is schema, and a business value is a lib constant. Logging, metrics, and tracing are exempt from the layer rules: the composition root configures them, and any layer may emit them directly.

## Placing new code

27. To place a piece of code, ask in order: does it talk to infrastructure (core)? Does it call core under one business name (operation)? Does it sequence business actions into a use case (workflow)? Does it translate a transport (entry point)? If none of these, it must be pure, and it goes in lib or types.
28. Data work is placed the same way. Writing a raw or derived record is an operation. Rebuilding a derived table from its sources is a workflow. A derivation rule that needs no I/O is a helper.

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
