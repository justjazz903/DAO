-- Chat application with a single, unbounded memory context per user.
-- Target: PostgreSQL 15+ with the pgvector extension.

CREATE EXTENSION IF NOT EXISTS vector;

CREATE TYPE message_role AS ENUM ('user', 'assistant', 'system', 'tool');
CREATE TYPE invocation_status AS ENUM ('pending', 'succeeded', 'failed', 'cancelled');
CREATE TYPE memory_status AS ENUM ('active', 'superseded', 'retracted');

-- Account identities. Everything else hangs off a user.
CREATE TABLE users (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    external_id   text UNIQUE,                 -- subject id from the auth provider
    display_name  text,
    timezone      text,                        -- IANA name, used to render relative dates in prompts
    created_at    timestamptz NOT NULL DEFAULT now(),
    deleted_at    timestamptz                  -- soft delete; rows are purged by a background job
);

-- One row per LLM call, kept for audit, cost tracking and reproducibility.
CREATE TABLE llm_invocations (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id            uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    model              text NOT NULL,
    status             invocation_status NOT NULL DEFAULT 'pending',
    context_manifest   jsonb,                  -- ids of messages, summaries and memories that were assembled into the prompt
    prompt_tokens      integer,
    completion_tokens  integer,
    latency_ms         integer,
    error              text,
    started_at         timestamptz NOT NULL DEFAULT now(),
    finished_at        timestamptz
);

CREATE INDEX llm_invocations_user_started_idx ON llm_invocations (user_id, started_at DESC);

-- The single message stream per user. There is no session grouping; order is by seq.
CREATE TABLE messages (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id        uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    seq            bigint GENERATED ALWAYS AS IDENTITY,   -- global monotonic position; gives a stable total order within a user's stream
    role           message_role NOT NULL,
    content        text NOT NULL,
    invocation_id  uuid REFERENCES llm_invocations(id) ON DELETE SET NULL, -- the call that produced (assistant/tool) or triggered (user) this message
    tool_call_id   text,                                  -- correlates a tool result with the assistant tool call that requested it
    embedding      vector(1536),                          -- for recalling specific past exchanges that fell out of the context window
    metadata       jsonb NOT NULL DEFAULT '{}'::jsonb,    -- attachments, client info, tool arguments, etc.
    created_at     timestamptz NOT NULL DEFAULT now(),
    UNIQUE (user_id, seq)
);

CREATE INDEX messages_embedding_idx ON messages USING hnsw (embedding vector_cosine_ops);

-- Compacted summaries of older message ranges so the whole history fits in a context window.
CREATE TABLE history_summaries (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    from_seq    bigint NOT NULL,
    to_seq      bigint NOT NULL,              -- inclusive; the summary replaces messages with from_seq <= seq <= to_seq in the prompt
    summary     text NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    CHECK (from_seq <= to_seq),
    UNIQUE (user_id, from_seq)
);

-- Distilled long-term facts about a user. This is the memory that persists across every invocation.
CREATE TABLE memories (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id           uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    kind              text NOT NULL,          -- coarse category: 'profile', 'preference', 'fact', 'goal', 'relationship', 'episode'
    content           text NOT NULL,          -- one natural-language statement, phrased so it can be injected into a prompt verbatim
    embedding         vector(1536),
    search_vector     tsvector GENERATED ALWAYS AS (to_tsvector('english', content)) STORED, -- lexical half of hybrid retrieval
    importance        smallint NOT NULL DEFAULT 5 CHECK (importance BETWEEN 1 AND 10),      -- retrieval weight assigned when the memory is written
    confidence        real NOT NULL DEFAULT 1.0 CHECK (confidence BETWEEN 0 AND 1),         -- how certain the extractor was; low values are stated tentatively
    pinned            boolean NOT NULL DEFAULT false,  -- always included in context regardless of retrieval score
    status            memory_status NOT NULL DEFAULT 'active',
    superseded_by     uuid REFERENCES memories(id) ON DELETE SET NULL, -- newer memory that replaced this one; old row is kept for history
    last_accessed_at  timestamptz,            -- last time this memory was placed into a prompt; drives decay and pruning
    access_count      integer NOT NULL DEFAULT 0,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX memories_user_active_idx ON memories (user_id) WHERE status = 'active';
CREATE INDEX memories_embedding_idx   ON memories USING hnsw (embedding vector_cosine_ops);
CREATE INDEX memories_search_idx      ON memories USING gin (search_vector);

-- Evidence: which messages each memory was derived from.
CREATE TABLE memory_sources (
    memory_id   uuid NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
    message_id  uuid NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    PRIMARY KEY (memory_id, message_id)
);

-- Small set of structured, deterministic facts (name, language, pronouns) read on every call without retrieval.
CREATE TABLE user_profile (
    user_id           uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    key               text NOT NULL,
    value             jsonb NOT NULL,
    source_memory_id  uuid REFERENCES memories(id) ON DELETE SET NULL, -- memory this attribute was promoted from, if any
    updated_at        timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, key)
);
