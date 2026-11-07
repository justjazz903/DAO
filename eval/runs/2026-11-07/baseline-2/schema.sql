-- Chat application with a single, unified long-term memory context per user.
-- Target: PostgreSQL 15+ with the pgvector extension.

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TYPE message_role AS ENUM ('user', 'assistant', 'system', 'tool');
CREATE TYPE invocation_status AS ENUM ('running', 'succeeded', 'failed', 'cancelled');
CREATE TYPE memory_kind AS ENUM ('fact', 'preference', 'goal', 'relationship', 'event', 'instruction', 'other');

-- Registered users of the application.
CREATE TABLE users (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    external_id   text UNIQUE,                    -- identity-provider subject; NULL for local accounts
    display_name  text NOT NULL,
    timezone      text NOT NULL DEFAULT 'UTC',    -- IANA name, used to render relative dates in context
    created_at    timestamptz NOT NULL DEFAULT now(),
    deleted_at    timestamptz                     -- soft delete; non-NULL rows are excluded from all context
);

-- One row per LLM call made for a user; records what context the call ran with.
CREATE TABLE invocations (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id             uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    status              invocation_status NOT NULL DEFAULT 'running',
    model               text NOT NULL,
    summary_id          uuid,                     -- memory_summaries row loaded into the prompt (FK added below)
    context_from_seq    bigint,                   -- first message seq included verbatim in the prompt window
    prompt_tokens       integer,
    completion_tokens   integer,
    error               text,
    started_at          timestamptz NOT NULL DEFAULT now(),
    finished_at         timestamptz
);
CREATE INDEX invocations_user_started_idx ON invocations (user_id, started_at DESC);

-- Append-only transcript of every message exchanged with a user; there is no conversation grouping.
CREATE TABLE messages (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    invocation_id   uuid REFERENCES invocations(id) ON DELETE SET NULL,  -- NULL for user messages received before a call starts
    seq             bigint GENERATED ALWAYS AS IDENTITY,  -- global monotonic order; stable across clock skew
    role            message_role NOT NULL,
    content         text NOT NULL,
    tool_name       text,                         -- set when role = 'tool'
    token_count     integer,
    embedding       vector(1536),                 -- for semantic recall of older turns no longer in the prompt window
    metadata        jsonb NOT NULL DEFAULT '{}',  -- attachments, client info, tool call ids
    created_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (user_id, seq)
);
CREATE INDEX messages_user_seq_idx ON messages (user_id, seq DESC);
CREATE INDEX messages_embedding_idx ON messages USING hnsw (embedding vector_cosine_ops);

-- Discrete, durable facts the assistant has learned about a user; the core of long-term memory.
CREATE TABLE memories (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id             uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    kind                memory_kind NOT NULL DEFAULT 'fact',
    content             text NOT NULL,            -- one self-contained natural-language statement
    embedding           vector(1536) NOT NULL,
    confidence          real NOT NULL DEFAULT 1.0 CHECK (confidence BETWEEN 0 AND 1),
    importance          smallint NOT NULL DEFAULT 5 CHECK (importance BETWEEN 1 AND 10),  -- ranking weight at retrieval time
    source_message_id   uuid REFERENCES messages(id) ON DELETE SET NULL,  -- message the fact was extracted from
    superseded_by_id    uuid REFERENCES memories(id) ON DELETE SET NULL,  -- newer memory that replaces this one
    valid_from          timestamptz NOT NULL DEFAULT now(),               -- when the fact became true, not when it was stored
    valid_until         timestamptz,                                      -- NULL while the fact still holds
    last_accessed_at    timestamptz,                                      -- last time injected into a prompt; drives decay
    access_count        integer NOT NULL DEFAULT 0,
    created_at          timestamptz NOT NULL DEFAULT now(),
    deleted_at          timestamptz                                       -- user-requested forget; kept for audit
);
CREATE INDEX memories_user_active_idx ON memories (user_id, importance DESC)
    WHERE superseded_by_id IS NULL AND valid_until IS NULL AND deleted_at IS NULL;
CREATE INDEX memories_embedding_idx ON memories USING hnsw (embedding vector_cosine_ops);

-- Versioned condensed narrative of everything known about a user; the latest version is loaded into every call.
CREATE TABLE memory_summaries (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id             uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    version             integer NOT NULL,
    content             text NOT NULL,
    covers_through_seq  bigint NOT NULL,          -- highest messages.seq folded into this summary
    token_count         integer,
    created_at          timestamptz NOT NULL DEFAULT now(),
    UNIQUE (user_id, version)
);

ALTER TABLE invocations
    ADD CONSTRAINT invocations_summary_fk
    FOREIGN KEY (summary_id) REFERENCES memory_summaries(id) ON DELETE SET NULL;

-- Which memories were retrieved and injected into a given invocation; audit and relevance tuning.
CREATE TABLE invocation_memories (
    invocation_id   uuid NOT NULL REFERENCES invocations(id) ON DELETE CASCADE,
    memory_id       uuid NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
    similarity      real,                         -- cosine similarity to the triggering user message
    rank            smallint NOT NULL,            -- position in the injected list
    PRIMARY KEY (invocation_id, memory_id)
);
CREATE INDEX invocation_memories_memory_idx ON invocation_memories (memory_id);
