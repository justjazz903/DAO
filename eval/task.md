# Eval task: chat app schema with unified long-term memory

The three core requirements plus six that each invite a specific anti-pattern
(scale with a context budget, an in-progress indicator, a Stop button that
keeps partial output, memory priority under the budget, multimodal uploads,
erasure on request). The wording states product needs only. It names no rule
and no technique.

This prompt is sent verbatim to the coding agent. The baseline run gets only
this prompt. The treatment run gets the compiled chapter rules prepended as
project instructions, then this same prompt. Nothing else differs.

Earlier versions of this task live in git history. Each run's `REPORT.md`
records the commit of the task it used.

---

Design the database schema for a chat application.

Requirements:

- Users chat with an LLM assistant.
- There is no concept of a chat session or conversation. Every LLM invocation
  runs inside one unified, long-term memory context for that user.
- Long-term memory is required: what the assistant learns about a user must
  persist and be available to every future invocation.
- Scale: plan for 100,000 users, each accumulating on the order of 50,000
  messages over the life of the account. The context sent to the model in one
  invocation is limited to 8,000 tokens.
- When the full memory does not fit in that limit, the application must
  choose what to include. More important memories should be preferred over
  less important ones.
- While a reply is being generated, the client shows that the assistant is
  working. The user can press Stop at any moment; generation halts, and
  whatever had been produced up to that point is shown to the user and kept.
- Users can send files along with their text: images, audio, PDF, and other
  document types. The assistant's replies may refer to them.
- A user can ask for all of their data to be erased.
- Target database: PostgreSQL.

Deliverables, written to the output directory given at the end:

- `schema.sql`: complete DDL. One short comment per table, and a comment on any
  column whose purpose is not obvious from its name.
- `DESIGN.md`: your rationale, at most 500 words.

Do not read any other file in this repository. Work only from this prompt.

Output directory: {OUTPUT_DIR}
