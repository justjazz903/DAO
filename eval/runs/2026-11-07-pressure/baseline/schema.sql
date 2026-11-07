-- Chat application with per-user long-term memory.
-- Target: PostgreSQL 14+. No extensions required (pgcrypto's gen_random_uuid()
-- is built in since PG 13).

BEGIN;

CREATE TYPE user_status     AS ENUM ('active', 'erasing');
CREATE TYPE message_role    AS ENUM ('user', 'assistant');
CREATE TYPE message_status  AS ENUM ('generating', 'complete', 'stopped', 'failed');
CREATE TYPE memory_kind     AS ENUM ('fact', 'preference', 'summary');
CREATE TYPE memory_state    AS ENUM ('active', 'superseded', 'retracted');
CREATE TYPE file_kind       AS ENUM ('image', 'audio', 'pdf', 'document', 'other');
CREATE TYPE file_status     AS ENUM ('pending', 'ready', 'failed');
CREATE TYPE derivation_kind AS ENUM ('text', 'transcript', 'caption', 'thumbnail');
CREATE TYPE erasure_status  AS ENUM ('requested', 'blobs_purged', 'done');


-- One row per account. Everything else hangs off users.id with ON DELETE CASCADE,
-- so erasing an account is a single DELETE once object-store blobs are gone.
CREATE TABLE users (
    id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    auth_subject  text        NOT NULL UNIQUE,   -- subject id from the identity provider; no password stored here
    display_name  text,
    status        user_status NOT NULL DEFAULT 'active',   -- 'erasing' blocks new invocations while purge runs
    created_at    timestamptz NOT NULL DEFAULT now()
);


-- Every message either side sent, in one unbroken stream per user (no sessions).
-- An assistant row is also the record of the LLM invocation that produced it,
-- because invocation and reply are 1:1. Hash-partitioned on user_id so that
-- ~5e9 rows stay maintainable; PK (user_id, id) serves "latest N for user".
CREATE SEQUENCE message_id_seq AS bigint;

CREATE TABLE messages (
    user_id             uuid           NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    id                  bigint         NOT NULL DEFAULT nextval('message_id_seq'),
    role                message_role   NOT NULL,
    content             text           NOT NULL DEFAULT '',   -- grows while an assistant reply streams; partial text is kept on Stop
    token_count         integer,                             -- cached tokenizer count of content; NULL until the message is final
    status              message_status NOT NULL DEFAULT 'complete',
    created_at          timestamptz    NOT NULL DEFAULT now(),
    completed_at        timestamptz,                         -- set when status leaves 'generating'
    -- assistant-only columns
    reply_to_message_id bigint,                              -- the user message that triggered this reply
    model               text,                                -- model identifier used for the invocation
    prompt_tokens       integer,                             -- size of the assembled context actually sent (<= 8000)
    context_memory_ids  bigint[],                            -- memories included in that context; audit only, may be nulled by retention
    stop_requested_at   timestamptz,                         -- set by the API on Stop; the generation worker polls it and halts
    error               text,                                -- failure detail when status = 'failed'
    PRIMARY KEY (user_id, id),
    FOREIGN KEY (user_id, reply_to_message_id) REFERENCES messages (user_id, id) ON DELETE CASCADE,
    CHECK (role = 'assistant'
           OR (status = 'complete' AND reply_to_message_id IS NULL AND model IS NULL
               AND stop_requested_at IS NULL AND prompt_tokens IS NULL)),
    CHECK ((status = 'generating') = (completed_at IS NULL))
) PARTITION BY HASH (user_id);

DO $$
BEGIN
    FOR i IN 0..63 LOOP
        EXECUTE format(
            'CREATE TABLE messages_p%s PARTITION OF messages FOR VALUES WITH (MODULUS 64, REMAINDER %s)',
            i, i);
    END LOOP;
END $$;

-- At most one reply in flight per user; also a tiny index for finding it.
CREATE UNIQUE INDEX messages_one_generating_per_user
    ON messages (user_id) WHERE status = 'generating';


-- Uploaded files. Bytes live in object storage; this row is the metadata.
CREATE TABLE files (
    id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id        uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    kind           file_kind   NOT NULL,
    content_type   text        NOT NULL,                       -- MIME type as uploaded
    original_name  text,
    byte_size      bigint      NOT NULL CHECK (byte_size >= 0),
    sha256         bytea       CHECK (octet_length(sha256) = 32),  -- for dedup / integrity checks
    storage_key    text        NOT NULL UNIQUE,                 -- object-store path; the erasure job deletes these before the row
    status         file_status NOT NULL DEFAULT 'pending',     -- 'ready' once the upload is confirmed in object storage
    created_at     timestamptz NOT NULL DEFAULT now(),
    UNIQUE (user_id, id)                                       -- lets message_files enforce same-user ownership
);


-- Model-readable renditions of a file (PDF text, audio transcript, image caption,
-- thumbnail). The context builder includes `content` rather than the raw bytes.
CREATE TABLE file_derivations (
    id           bigint          GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    file_id      uuid            NOT NULL REFERENCES files (id) ON DELETE CASCADE,
    kind         derivation_kind NOT NULL,
    content      text,                      -- textual rendition; NULL for binary renditions such as thumbnails
    storage_key  text,                      -- object-store path for binary renditions
    token_count  integer,                   -- cached token size of content, for context packing
    producer     text,                      -- model or tool that produced it (e.g. 'whisper-1', 'pdftotext')
    created_at   timestamptz     NOT NULL DEFAULT now(),
    UNIQUE (file_id, kind),
    CHECK (content IS NOT NULL OR storage_key IS NOT NULL)
);


-- Which files are attached to which message. Assistant replies can reference
-- files too (e.g. a file it generated or is answering about).
CREATE TABLE message_files (
    user_id     uuid     NOT NULL,
    message_id  bigint   NOT NULL,
    file_id     uuid     NOT NULL,
    position    smallint NOT NULL DEFAULT 0,   -- display order within the message
    PRIMARY KEY (message_id, file_id),
    FOREIGN KEY (user_id, message_id) REFERENCES messages (user_id, id) ON DELETE CASCADE,
    FOREIGN KEY (user_id, file_id)    REFERENCES files    (user_id, id) ON DELETE CASCADE
);

CREATE INDEX message_files_file_idx ON message_files (file_id);


-- Long-term memory: distilled facts, preferences, and rolling summaries of
-- message spans. This, not the raw message log, is what feeds the 8k context.
CREATE TABLE memories (
    id                    bigint       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id               uuid         NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    kind                  memory_kind  NOT NULL,
    content               text         NOT NULL,
    token_count           integer      NOT NULL,                     -- cached; the packer sums this against the budget
    importance            real         NOT NULL CHECK (importance BETWEEN 0 AND 1),  -- extractor-assigned; higher wins when space is short
    state                 memory_state NOT NULL DEFAULT 'active',
    superseded_by_id      bigint       REFERENCES memories (id) ON DELETE SET NULL,  -- newer memory that replaced this one
    span_start_message_id bigint,                                    -- for kind = 'summary': first message covered
    span_end_message_id   bigint,                                    -- for kind = 'summary': last message covered
    use_count             integer      NOT NULL DEFAULT 0,           -- times included in a context; feeds importance adjustment
    last_used_at          timestamptz,                               -- tie-breaker after importance; also drives decay
    created_at            timestamptz  NOT NULL DEFAULT now(),
    updated_at            timestamptz  NOT NULL DEFAULT now(),
    search                tsvector     GENERATED ALWAYS AS (to_tsvector('simple', content)) STORED,  -- lexical relevance to the new prompt
    FOREIGN KEY (user_id, span_start_message_id) REFERENCES messages (user_id, id) ON DELETE CASCADE,
    FOREIGN KEY (user_id, span_end_message_id)   REFERENCES messages (user_id, id) ON DELETE CASCADE,
    CHECK ((kind = 'summary') = (span_start_message_id IS NOT NULL AND span_end_message_id IS NOT NULL)),
    CHECK ((state = 'superseded') = (superseded_by_id IS NOT NULL))
);

-- Context selection: active memories for a user, most important first.
CREATE INDEX memories_select_idx
    ON memories (user_id, importance DESC, last_used_at DESC)
    WHERE state = 'active';

CREATE INDEX memories_search_idx ON memories USING gin (search);


-- Provenance: which messages a fact/preference memory was extracted from.
CREATE TABLE memory_sources (
    memory_id   bigint NOT NULL REFERENCES memories (id) ON DELETE CASCADE,
    user_id     uuid   NOT NULL,
    message_id  bigint NOT NULL,
    PRIMARY KEY (memory_id, message_id),
    FOREIGN KEY (user_id, message_id) REFERENCES messages (user_id, id) ON DELETE CASCADE
);

CREATE INDEX memory_sources_message_idx ON memory_sources (user_id, message_id);


-- Audit of "erase all my data" requests. Deliberately has no FK to users and
-- holds no personal data, so it survives the deletion it records.
CREATE TABLE erasure_requests (
    id               bigint         GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id          uuid           NOT NULL,   -- the erased account's id; dangling by design after completion
    status           erasure_status NOT NULL DEFAULT 'requested',
    requested_at     timestamptz    NOT NULL DEFAULT now(),
    blobs_purged_at  timestamptz,               -- all files.storage_key objects deleted from object storage
    completed_at     timestamptz                -- users row deleted; cascades removed every other row
);

CREATE INDEX erasure_requests_pending_idx
    ON erasure_requests (requested_at) WHERE status <> 'done';

COMMIT;
