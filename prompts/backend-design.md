# Backend design

Apply these rules to every backend service: what it records, where code goes, and what code may call or know.

## Build what is asked for

1. **Model only the requirements stated now:** no tables, columns, parameters, or abstractions for ones you imagine coming later.

## Every definition is a boundary

2. **Every schema, module, and function defines what the system does and, by exclusion, what it does not.** Features are built in the space boundaries leave open, so draw each one on purpose: if you cannot say what a piece refuses to do, it has no boundary.
3. **A capability never knows its consumer:** nothing in it names or assumes what is built on it, so a second consumer can stand on it unchanged. This costs overhead and buys reuse: pay it. Rule 1 still holds: draw the boundary, but build only the parts the current consumer needs.
4. **The same rule holds at every scale**, from one service over another down to the atomic core function: each piece knows what it stands on and nothing about what stands on it or beside it.

## Facts first, structure second

5. **List the raw facts the system will record**, then derive structure from them.
6. **Any claim about speed, size, or cost** carries a number or the word "unknown".

## Names mean one thing

7. **A name carries one kind of thing:** if one sentence cannot say what a table or type holds, split it. A name may widen to new cases only if every field still means the same thing in every record (rename it if the old name fits only the old scope); otherwise create a new name. A flag never changes what another field means.

## Keep raw and derived apart

8. **A value is derived only if the exact same value can be recomputed from raw records** (a total, a score computed by code). Compute it on read; store it only when that is measured too slow or the raw store cannot answer the query (full-text or vector search).
9. **Anything that cannot be recomputed exactly is a fact:** a person's judgement, a model's output, a provider's answer. Record it raw with who or what produced it and when; for a model or provider, also its inputs and version.
10. **A derived record stores which raw records it came from**, as fields a lookup can follow.
11. **Keep raw and derived in separate tables.** Raw records are never updated or deleted: a change, even a correction, is a new record. A derived table is never the source of truth: it can be dropped and rebuilt entirely from its sources. Never derive a table from one derived from it.
12. **Track state by appending one record per change:** an event for a lifecycle step, a new version for an edited attribute. Current state is derived; if stored, it is a derived table updated in the same operation. Constantly changing values whose history nobody needs (rate-limit counters, last seen) go in a cache, not in raw records.

## Three layers, nothing else

13. **Code has exactly three layers: core, operations, workflows.** Never add a fourth or rename them.
14. **Core talks to infrastructure and knows nothing about the business.** It knows the schema, but every business value (a threshold, which statuses count) arrives as a parameter: selecting invoices due before a date is core; deciding which date makes one overdue is the operation's job. Each function does one atomic thing: one query, one endpoint call, one cache read, one published event.
15. **Operations compose core calls into one business action with one name:** register a user, call provider A then provider B with its answer. Business rules and domain validation are applied here.
16. **Workflows sequence operations into one complete use case.** For a chat turn: load context, generate the reply, save both messages, update the profile. They decide only order, branching, and what happens on failure.
17. **Name each function in its layer's vocabulary.** Core functions are named after the infrastructure action (insert row, post request), operations and workflows after the business action (save exchange, handle turn). A name outside its layer's vocabulary means the code is in the wrong layer.

## Calls go one way, one step

18. **Each layer calls only the layer directly beneath it:** workflows call operations, operations call core, core calls infrastructure. A workflow never touches core, even for one read; a pass-through operation that only calls one core function is legitimate, even as a one-line alias.
19. **No sibling calls:** operations never call operations, workflows never call workflows. Instead:
   - a shared pure rule becomes a helper;
   - a shared read is done once by the workflow and passed down;
   - two actions that must succeed or fail together are one operation that repeats the core calls it needs.
20. **Errors move up one layer at a time.** Core raises typed infrastructure errors (not found, timeout, conflict), operations decide what each means for the business, and workflows decide whether to retry, compensate, or fail the use case.
21. **Anything that can run twice must be safe to repeat:** an operation a workflow retries, a workflow started from a queue (queues redeliver). A second run changes nothing.
22. **A transaction begins and ends inside one operation**, in a scope core provides; every core call inside it shares the transaction. Never hold a transaction open across a call to another service.
23. **Workflows sequence, events trigger.** Within a use case, the workflow sequences what follows a state change. Anything outside it that must react is triggered by an event emitted by the operation that made the change, never by polling for the change.

## Entry points translate, then delegate

24. **HTTP handlers, queue consumers, cron jobs, and CLI commands are entry points, not a layer.** Each parses and validates the transport's input, builds a typed request, calls one workflow, and maps the result or error back into the transport's vocabulary: status code, ack or nack, exit code.
25. **Entry points never import operations or core.** The same workflow must run unchanged from HTTP, a queue, a CLI, and a unit test.
26. **Middleware, including authentication, is entry-point code.** Authorization, whether this caller may do this thing, is a business rule and belongs in an operation.

## Helpers are pure, shapes are data

27. **A helper is a pure function:** no I/O, clock, randomness, environment reads, or imports from any layer. Time and randomness are infrastructure and enter through core. Group helpers by subject (text, money, dates), never under utils, helpers, or common.
28. **A pure helper may know the domain:** it lives in lib under its subject (pricing, eligibility), may serve any number of operations, and imports only shapes. Business values (retry limits, plan quotas) live in lib too, as named constants, each defined once.
29. **Domain shapes, request and response shapes, and error types live in one shapes module with no behaviour.** Every layer imports it; it imports nothing from the project. A declarative validation schema belongs there if it declares only shape and format, no business rules.

## Wire once

30. **Layers are joined by ordinary imports:** each layer imports only the layer beneath it, shapes, and lib. One composition root reads config, builds the database pool, HTTP clients, and queue connections, hands them into core as module state set once at startup, and starts the entry points. It is the only file that reads environment variables or imports all three layers.
31. **Config is only what differs between deployments:** connection details, pool sizes, timeouts, resource names that vary by environment. It goes into core with the clients. A table name that is the same everywhere is schema; a business value is a lib constant.
32. **Logging, metrics, and tracing are exempt from the layer rules:** the composition root configures them, and any layer may emit them directly.

## Placing data work

33. **Where data work goes:**
   - Appending a raw record or writing a derived record is an operation.
   - Rebuilding a derived table from its sources is a workflow.
   - A derivation rule that needs no I/O is a helper.

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
  shapes/         data and error types, no logic
  lib/            pure helpers and business constants, grouped by subject
```
