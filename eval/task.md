# Eval task: chat app schema with unified long-term memory

This prompt is sent verbatim to the coding agent. The baseline run gets only
this prompt. The treatment run gets the compiled chapter rules prepended as
project instructions, then this same prompt. Nothing else differs.

---

Design the database schema for a chat application.

Requirements:

- Users chat with an LLM assistant.
- There is no concept of a chat session or conversation. Every LLM invocation
  runs inside one unified, long-term memory context for that user.
- Long-term memory is required: what the assistant learns about a user must
  persist and be available to every future invocation.
- Target database: PostgreSQL.

Deliverables, written to the output directory given at the end:

- `schema.sql`: complete DDL. One short comment per table, and a comment on any
  column whose purpose is not obvious from its name.
- `DESIGN.md`: your rationale, at most 300 words.

Do not read any other file in this repository. Work only from this prompt.

Output directory: {OUTPUT_DIR}
