-- Chat application with one unified, long-term memory context per user.
-- PostgreSQL 15+. pgvector is used for semantic recall of memory items.

CREATE EXTENSION IF NOT EXISTS vector;

-- Account record for each person who chats with the assistant.
CREATE TABLE users (
    id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    external_id   TEXT        NOT NULL UNIQUE,   -- identity from the auth provider
    display_name  TEXT,
    timezone      TEXT        NOT NULL DEFAULT 'UTC',
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at    TIMESTAMPTZ                    -- soft delete; memory is purged by a job
);

-- One row per LLM call. There are no sessions; each call is a point on the user's
-- single timeline and records exactly what context was assembled for it.
CREATE TABLE invocations (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id             BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    model               TEXT        NOT NULL,
    status              TEXT        NOT NULL DEFAULT 'running'
                        CHECK (status IN ('running', 'succeeded', 'failed', 'cancelled')),
    started_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at         TIMESTAMPTZ,
    profile_version_id  BIGINT,     -- which profile snapshot was in the prompt (FK added below)
    summary_id          BIGINT,     -- which timeline summary was in the prompt (FK added below)
    context_window      JSONB       NOT NULL DEFAULT '{}'::jsonb, -- ids of messages/memory items actually sent, for audit and replay
    prompt_tokens       INTEGER,
    completion_tokens   INTEGER,
    error               TEXT
);
CREATE INDEX invocations_user_started_idx ON invocations (user_id, started_at DESC);

-- The user's single, append-only message timeline (user turns, assistant turns, tool results).
CREATE TABLE messages (
    id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id        BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    invocation_id  BIGINT      REFERENCES invocations(id) ON DELETE SET NULL, -- the call that produced (assistant) or consumed (user/tool) this message
    role           TEXT        NOT NULL CHECK (role IN ('user', 'assistant', 'tool', 'system')),
    content        TEXT        NOT NULL,
    content_json   JSONB,      -- structured payload when content is not plain text (tool calls, attachments)
    token_count    INTEGER,    -- cached count used for context-window packing
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX messages_user_id_idx ON messages (user_id, id);
CREATE INDEX messages_invocation_idx ON messages (invocation_id);

-- Rolling compaction of older messages so the full timeline never has to fit in a prompt.
-- Each row summarises a contiguous id range; the newest row for a user is the one injected.
CREATE TABLE timeline_summaries (
    id                BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id           BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    from_message_id   BIGINT      NOT NULL REFERENCES messages(id),
    to_message_id     BIGINT      NOT NULL REFERENCES messages(id),
    supersedes_id     BIGINT      REFERENCES timeline_summaries(id), -- previous summary folded into this one
    content           TEXT        NOT NULL,
    token_count       INTEGER,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (from_message_id <= to_message_id)
);
CREATE INDEX timeline_summaries_user_latest_idx ON timeline_summaries (user_id, to_message_id DESC);

-- Discrete, durable facts the assistant has learned about the user (long-term memory).
-- Rows are never edited in place; a correction inserts a new row and retires the old one.
CREATE TABLE memory_items (
    id                 BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id            BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    kind               TEXT        NOT NULL
                       CHECK (kind IN ('fact', 'preference', 'goal', 'relationship', 'event', 'instruction')),
    content            TEXT        NOT NULL,       -- one self-contained natural-language statement
    confidence         REAL        NOT NULL DEFAULT 1.0 CHECK (confidence BETWEEN 0 AND 1),
    importance         SMALLINT    NOT NULL DEFAULT 3 CHECK (importance BETWEEN 1 AND 5), -- retrieval priority when the budget is tight
    embedding          vector(1536),               -- semantic index for recall; dimension matches the embedding model
    source_message_id  BIGINT      REFERENCES messages(id) ON DELETE SET NULL, -- where the fact was learned
    superseded_by_id   BIGINT      REFERENCES memory_items(id),                -- set when a newer item replaces this one
    retired_at         TIMESTAMPTZ,                -- non-null means no longer injected into prompts
    last_recalled_at   TIMESTAMPTZ,                -- feeds decay / eviction heuristics
    recall_count       INTEGER     NOT NULL DEFAULT 0,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX memory_items_user_active_idx ON memory_items (user_id, importance DESC) WHERE retired_at IS NULL;
CREATE INDEX memory_items_embedding_idx ON memory_items USING hnsw (embedding vector_cosine_ops);

-- Versioned, prose synthesis of the active memory items: the compact "who this user is"
-- block that is prepended to every invocation. Rebuilt when memory items change.
CREATE TABLE profile_versions (
    id          BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id     BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    version     INTEGER     NOT NULL,
    content     TEXT        NOT NULL,
    token_count INTEGER,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, version)
);

ALTER TABLE invocations
    ADD CONSTRAINT invocations_profile_version_fk
        FOREIGN KEY (profile_version_id) REFERENCES profile_versions(id) ON DELETE SET NULL,
    ADD CONSTRAINT invocations_summary_fk
        FOREIGN KEY (summary_id) REFERENCES timeline_summaries(id) ON DELETE SET NULL;

-- Which memory items were injected into which invocation; supports audit and recall stats.
CREATE TABLE invocation_memory_uses (
    invocation_id   BIGINT NOT NULL REFERENCES invocations(id) ON DELETE CASCADE,
    memory_item_id  BIGINT NOT NULL REFERENCES memory_items(id) ON DELETE CASCADE,
    PRIMARY KEY (invocation_id, memory_item_id)
);
CREATE INDEX invocation_memory_uses_item_idx ON invocation_memory_uses (memory_item_id);
