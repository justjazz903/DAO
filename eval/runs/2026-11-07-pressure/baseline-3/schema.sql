-- Chat application with a single long-term memory context per user.
-- Requires PostgreSQL 16 or later.
--
-- Conventions:
--   * Every row that belongs to a user carries user_id and a cascading FK to
--     users, so `DELETE FROM users WHERE id = $1` erases all of that user's rows.
--   * High-volume tables (messages, generations, message_files) are hash-
--     partitioned by user_id; every query is scoped to one user, so a query
--     touches exactly one partition.
--   * Token counts are stored on anything that can be placed in a prompt, so
--     the 8,000-token budget can be enforced in SQL.

CREATE TYPE message_role    AS ENUM ('user', 'assistant');
CREATE TYPE message_status  AS ENUM ('complete', 'generating', 'stopped', 'failed');
CREATE TYPE finish_reason   AS ENUM ('end_turn', 'max_tokens', 'stopped_by_user', 'error');
CREATE TYPE file_kind       AS ENUM ('image', 'audio', 'pdf', 'document', 'other');
CREATE TYPE file_status     AS ENUM ('uploaded', 'processing', 'ready', 'failed');
CREATE TYPE file_relation   AS ENUM ('attachment', 'reference');
CREATE TYPE memory_kind     AS ENUM ('fact', 'preference', 'goal', 'relationship', 'event', 'summary');
CREATE TYPE memory_state    AS ENUM ('active', 'superseded', 'retracted');
CREATE TYPE erasure_status  AS ENUM ('pending', 'running', 'done', 'failed');

CREATE SEQUENCE message_id_seq    AS bigint;
CREATE SEQUENCE generation_id_seq AS bigint;


-- One account. Owns everything else; deleting the row cascades to all user data.
CREATE TABLE users (
    id                              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    auth_subject                    text        NOT NULL UNIQUE,  -- subject id from the identity provider; the only login identifier kept here
    display_name                    text,
    timezone                        text        NOT NULL DEFAULT 'UTC',
    created_at                      timestamptz NOT NULL DEFAULT now(),
    summarized_through_message_id   bigint,                       -- messages with id <= this have been condensed into 'summary' memories
    erasure_requested_at            timestamptz                   -- set when the user asks for erasure; the account is locked from then on
);


-- Every user and assistant turn, in one per-user stream (there are no conversations).
CREATE TABLE messages (
    user_id       uuid           NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    id            bigint         NOT NULL DEFAULT nextval('message_id_seq'),  -- global, monotonic: orders the user's stream
    role          message_role   NOT NULL,
    status        message_status NOT NULL DEFAULT 'complete',
    content       text           NOT NULL DEFAULT '',  -- for a 'stopped' assistant message: the partial text produced before Stop
    token_count   integer        NOT NULL DEFAULT 0,   -- tokens of content under the serving model's tokenizer; used for context budgeting
    created_at    timestamptz    NOT NULL DEFAULT now(),
    completed_at  timestamptz,                         -- when generation finished, was stopped, or failed; NULL while 'generating'
    PRIMARY KEY (user_id, id),
    CHECK (role = 'assistant' OR status = 'complete')
) PARTITION BY HASH (user_id);


-- One LLM invocation producing one assistant message: run control, accounting, and what was in the prompt.
CREATE TABLE generations (
    user_id                  uuid          NOT NULL,
    id                       bigint        NOT NULL DEFAULT nextval('generation_id_seq'),
    user_message_id          bigint        NOT NULL,  -- the user message that triggered this run
    assistant_message_id     bigint        NOT NULL,  -- created with status 'generating' before the model is called
    model                    text          NOT NULL,
    started_at               timestamptz   NOT NULL DEFAULT now(),
    stop_requested_at        timestamptz,             -- set by the API when the user presses Stop; the worker halts on seeing it
    finished_at              timestamptz,
    finish_reason            finish_reason,
    error                    text,
    prompt_tokens            integer,
    completion_tokens        integer,
    context_memory_ids       bigint[]      NOT NULL DEFAULT '{}',  -- memories included in this prompt (audit; feeds recall stats)
    context_from_message_id  bigint,                               -- oldest message included verbatim in this prompt
    PRIMARY KEY (user_id, id),
    UNIQUE (user_id, assistant_message_id),
    FOREIGN KEY (user_id, user_message_id)      REFERENCES messages (user_id, id) ON DELETE CASCADE,
    FOREIGN KEY (user_id, assistant_message_id) REFERENCES messages (user_id, id) ON DELETE CASCADE
) PARTITION BY HASH (user_id);

-- In-flight runs only: used by the Stop endpoint and by crash recovery.
CREATE INDEX generations_running_idx ON generations (user_id, id) WHERE finished_at IS NULL;


-- A file a user uploaded (image, audio, PDF, document...). Bytes live in object storage.
CREATE TABLE files (
    id                 bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id            uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    kind               file_kind   NOT NULL,
    mime_type          text        NOT NULL,
    original_name      text        NOT NULL,
    byte_size          bigint      NOT NULL,
    storage_key        text        NOT NULL UNIQUE,  -- object-storage path; must be deleted from storage during erasure
    sha256             bytea       NOT NULL,
    status             file_status NOT NULL DEFAULT 'uploaded',  -- 'processing' while text/caption extraction runs
    width              integer,
    height             integer,
    duration_ms        integer,
    page_count         integer,
    extracted_text     text,                         -- PDF/document text or audio transcript, readable by the model
    caption            text,                         -- short model-written description used in the prompt when the file itself is not sent
    text_token_count   integer,                      -- tokens of extracted_text
    created_at         timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX files_user_idx ON files (user_id, id);


-- Links messages to files: a user message's attachments, or files an assistant reply refers to.
CREATE TABLE message_files (
    user_id     uuid          NOT NULL,
    message_id  bigint        NOT NULL,
    file_id     bigint        NOT NULL REFERENCES files (id) ON DELETE CASCADE,
    relation    file_relation NOT NULL,              -- 'attachment': sent with the message; 'reference': cited by the assistant
    position    smallint      NOT NULL DEFAULT 0,    -- display order within the message
    PRIMARY KEY (user_id, message_id, file_id),
    FOREIGN KEY (user_id, message_id) REFERENCES messages (user_id, id) ON DELETE CASCADE
) PARTITION BY HASH (user_id);

CREATE INDEX message_files_file_idx ON message_files (file_id);


-- Long-term memory: durable statements the assistant has learned about the user.
CREATE TABLE memories (
    id                  bigint        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id             uuid          NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    kind                memory_kind   NOT NULL,
    content             text          NOT NULL,      -- self-contained sentence(s), written to be pasted verbatim into the prompt
    token_count         integer       NOT NULL,
    importance          smallint      NOT NULL CHECK (importance BETWEEN 0 AND 100),  -- assigned at extraction; primary sort key for context selection
    state               memory_state  NOT NULL DEFAULT 'active',
    superseded_by_id    bigint        REFERENCES memories (id) ON DELETE SET NULL,     -- newer memory that replaces this one (state = 'superseded')
    source_message_id   bigint,                                                        -- message this was learned from, if any
    created_at          timestamptz   NOT NULL DEFAULT now(),
    updated_at          timestamptz   NOT NULL DEFAULT now(),
    last_recalled_at    timestamptz,                                                   -- last time it was placed in a prompt; tie-breaker among equal importance
    recall_count        integer       NOT NULL DEFAULT 0,
    FOREIGN KEY (user_id, source_message_id) REFERENCES messages (user_id, id) ON DELETE SET NULL (source_message_id)
);

-- Context selection path: a user's active memories, best first.
CREATE INDEX memories_select_idx
    ON memories (user_id, importance DESC, last_recalled_at DESC NULLS LAST, id DESC)
    WHERE state = 'active';


-- Queue and audit for "erase all my data". No FK: the row must outlive the user and holds no personal data.
CREATE TABLE erasure_requests (
    id                        bigint         GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id                   uuid           NOT NULL,
    status                    erasure_status NOT NULL DEFAULT 'pending',
    requested_at              timestamptz    NOT NULL DEFAULT now(),
    started_at                timestamptz,
    completed_at              timestamptz,
    storage_objects_deleted   integer        NOT NULL DEFAULT 0,  -- object-storage deletions completed before the DB cascade
    error                     text
);

CREATE INDEX erasure_requests_open_idx ON erasure_requests (requested_at) WHERE status IN ('pending', 'running');


-- Partitions for the per-user high-volume tables.
DO $$
DECLARE
    i integer;
BEGIN
    FOR i IN 0..63 LOOP
        EXECUTE format('CREATE TABLE messages_p%s      PARTITION OF messages      FOR VALUES WITH (MODULUS 64, REMAINDER %s)', i, i);
        EXECUTE format('CREATE TABLE generations_p%s   PARTITION OF generations   FOR VALUES WITH (MODULUS 64, REMAINDER %s)', i, i);
        EXECUTE format('CREATE TABLE message_files_p%s PARTITION OF message_files FOR VALUES WITH (MODULUS 64, REMAINDER %s)', i, i);
    END LOOP;
END
$$;


-- Picks a user's active memories for a prompt: highest importance first, until the token budget is used.
CREATE FUNCTION select_memories_for_context(p_user_id uuid, p_token_budget integer)
RETURNS SETOF memories
LANGUAGE sql STABLE
AS $$
    SELECT (s.m).*
    FROM (
        SELECT m AS m,
               sum(m.token_count) OVER w AS running_tokens
        FROM memories m
        WHERE m.user_id = p_user_id
          AND m.state = 'active'
        WINDOW w AS (ORDER BY m.importance DESC, m.last_recalled_at DESC NULLS LAST, m.id DESC)
    ) s
    WHERE s.running_tokens <= p_token_budget
    ORDER BY (s.m).importance DESC, (s.m).id DESC;
$$;
