-- Chat application schema: one long-term memory context per user, no conversations.
-- Target: PostgreSQL 14+.

CREATE EXTENSION IF NOT EXISTS pgcrypto;  -- gen_random_uuid()

-- ---------------------------------------------------------------------------
-- Enumerations
-- ---------------------------------------------------------------------------
CREATE TYPE message_role      AS ENUM ('user', 'assistant');
CREATE TYPE message_status    AS ENUM ('completed', 'generating', 'stopped', 'failed');
CREATE TYPE memory_kind       AS ENUM ('profile', 'preference', 'fact', 'goal', 'event', 'summary');
CREATE TYPE file_kind         AS ENUM ('image', 'audio', 'pdf', 'document', 'other');
CREATE TYPE file_status       AS ENUM ('uploading', 'ready', 'failed');
CREATE TYPE extraction_status AS ENUM ('pending', 'done', 'failed', 'skipped');
CREATE TYPE message_file_link AS ENUM ('attached', 'referenced');
CREATE TYPE erasure_status    AS ENUM ('queued', 'running', 'completed');

-- ---------------------------------------------------------------------------
-- users: one account; every other user-owned row cascades from here.
-- ---------------------------------------------------------------------------
CREATE TABLE users (
    id                   uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    external_id          text        NOT NULL UNIQUE,   -- subject id from the identity provider
    display_name         text,
    timezone             text        NOT NULL DEFAULT 'UTC',
    locale               text        NOT NULL DEFAULT 'en',
    created_at           timestamptz NOT NULL DEFAULT now(),
    last_seen_at         timestamptz,
    memory_cursor        bigint      NOT NULL DEFAULT 0, -- highest messages.id already processed by the memory extractor
    erasure_requested_at timestamptz                     -- set when erasure is requested; writes are refused after this
);

-- ---------------------------------------------------------------------------
-- messages: the single append-only timeline per user (user and assistant turns).
-- 100k users x 50k messages = 5e9 rows, so hash-partitioned on user_id.
-- ---------------------------------------------------------------------------
CREATE SEQUENCE message_id_seq AS bigint;

CREATE TABLE messages (
    user_id           uuid           NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    id                bigint         NOT NULL DEFAULT nextval('message_id_seq'), -- global sequence: ordering by id is creation order
    role              message_role   NOT NULL,
    status            message_status NOT NULL DEFAULT 'completed',               -- assistant rows only vary; 'stopped' keeps partial text
    content           text           NOT NULL DEFAULT '',
    token_count       integer        NOT NULL DEFAULT 0,                         -- precomputed for context budgeting
    created_at        timestamptz    NOT NULL DEFAULT now(),
    completed_at      timestamptz,                                               -- when generation finished, was stopped, or failed
    in_reply_to       bigint,                                                    -- assistant rows: the user message that triggered the invocation
    model             text,                                                      -- assistant rows: model identifier used
    prompt_tokens     integer,                                                   -- assistant rows: tokens of the assembled context sent
    completion_tokens integer,                                                   -- assistant rows: tokens actually generated
    stop_reason       text,                                                      -- assistant rows: provider stop reason, or 'user_stop'
    PRIMARY KEY (user_id, id),
    FOREIGN KEY (user_id, in_reply_to) REFERENCES messages(user_id, id) ON DELETE SET NULL,
    CHECK (role = 'assistant' OR status = 'completed'),
    CHECK (role = 'assistant' OR (model IS NULL AND in_reply_to IS NULL))
) PARTITION BY HASH (user_id);

DO $$
BEGIN
    FOR i IN 0..63 LOOP
        EXECUTE format(
            'CREATE TABLE messages_p%s PARTITION OF messages FOR VALUES WITH (MODULUS 64, REMAINDER %s)',
            i, i);
    END LOOP;
END $$;

-- Tiny partial index: "is the assistant currently working for this user?"
CREATE INDEX messages_generating_idx ON messages (user_id) WHERE status = 'generating';

-- ---------------------------------------------------------------------------
-- user_digest: one short, always-included summary of the user, rebuilt by the extractor.
-- ---------------------------------------------------------------------------
CREATE TABLE user_digest (
    user_id                    uuid        PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    content                    text        NOT NULL,
    token_count                integer     NOT NULL,
    built_through_message_id   bigint      NOT NULL, -- last message incorporated into this digest
    updated_at                 timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- memories: discrete long-term facts about a user, ranked by importance when the context is assembled.
-- ---------------------------------------------------------------------------
CREATE TABLE memories (
    id                bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id           uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    kind              memory_kind NOT NULL,
    content           text        NOT NULL,
    token_count       integer     NOT NULL,                       -- precomputed so selection is a window sum in SQL
    importance        real        NOT NULL CHECK (importance BETWEEN 0 AND 1), -- assigned at extraction; primary ranking key
    confidence        real        CHECK (confidence BETWEEN 0 AND 1),          -- how sure the extractor was
    is_active         boolean     NOT NULL DEFAULT true,          -- false once superseded or retracted
    superseded_by     bigint      REFERENCES memories(id) ON DELETE SET NULL,  -- newer memory that replaced this one
    source_user_id    uuid,
    source_message_id bigint,                                     -- message the memory was extracted from
    valid_until       timestamptz,                                -- for time-bounded facts; ranking decays past this
    use_count         integer     NOT NULL DEFAULT 0,             -- times included in a context; feeds ranking
    last_used_at      timestamptz,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (source_user_id, source_message_id) REFERENCES messages(user_id, id) ON DELETE SET NULL,
    CHECK (source_user_id IS NULL OR source_user_id = user_id)
);

-- The context assembler reads only active rows, best first.
CREATE INDEX memories_active_rank_idx ON memories (user_id, importance DESC, id) WHERE is_active;

-- ---------------------------------------------------------------------------
-- files: metadata for user uploads; bytes live in object storage under storage_key.
-- ---------------------------------------------------------------------------
CREATE TABLE files (
    id                uuid              PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id           uuid              NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    kind              file_kind         NOT NULL,
    mime_type         text              NOT NULL,
    byte_size         bigint            NOT NULL CHECK (byte_size >= 0),
    sha256            bytea,                                         -- content hash for dedup and integrity
    original_name     text,
    storage_key       text              NOT NULL UNIQUE,             -- object-storage path; never reused
    status            file_status       NOT NULL DEFAULT 'uploading',
    extracted_text    text,                                          -- OCR / transcript / PDF text so the file can enter the token budget
    extracted_tokens  integer,
    extraction_status extraction_status NOT NULL DEFAULT 'pending',
    created_at        timestamptz       NOT NULL DEFAULT now()
);

CREATE INDEX files_user_idx ON files (user_id, created_at DESC);

-- ---------------------------------------------------------------------------
-- message_files: links a file to a message, either as a user attachment or as something the assistant's reply refers to.
-- ---------------------------------------------------------------------------
CREATE TABLE message_files (
    user_id    uuid              NOT NULL,
    message_id bigint            NOT NULL,
    file_id    uuid              NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    link_kind  message_file_link NOT NULL, -- 'attached' on user messages, 'referenced' on assistant messages
    position   smallint          NOT NULL DEFAULT 0, -- display order within the message
    PRIMARY KEY (message_id, file_id),
    FOREIGN KEY (user_id, message_id) REFERENCES messages(user_id, id) ON DELETE CASCADE
);

CREATE INDEX message_files_file_idx ON message_files (file_id);

-- ---------------------------------------------------------------------------
-- erasure_requests: audit of "erase all my data" requests. No FK on purpose: it must outlive the user row.
-- ---------------------------------------------------------------------------
CREATE TABLE erasure_requests (
    id           bigint         GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id      uuid           NOT NULL, -- opaque id only; the users row is gone once completed
    status       erasure_status NOT NULL DEFAULT 'queued',
    requested_at timestamptz    NOT NULL DEFAULT now(),
    started_at   timestamptz,
    completed_at timestamptz
);

CREATE INDEX erasure_requests_pending_idx ON erasure_requests (requested_at) WHERE status <> 'completed';

-- ---------------------------------------------------------------------------
-- blob_deletion_queue: storage keys whose bytes must still be removed from object storage after the row is gone.
-- ---------------------------------------------------------------------------
CREATE TABLE blob_deletion_queue (
    id          bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    storage_key text        NOT NULL,
    enqueued_at timestamptz NOT NULL DEFAULT now(),
    deleted_at  timestamptz              -- set by the worker once the object is gone
);

CREATE INDEX blob_deletion_queue_pending_idx ON blob_deletion_queue (enqueued_at) WHERE deleted_at IS NULL;

-- Any deletion of a files row (including the cascade from users) enqueues its blob for removal.
CREATE FUNCTION enqueue_blob_deletion() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO blob_deletion_queue (storage_key) VALUES (OLD.storage_key);
    RETURN OLD;
END $$;

CREATE TRIGGER files_enqueue_blob_deletion
    AFTER DELETE ON files
    FOR EACH ROW EXECUTE FUNCTION enqueue_blob_deletion();
