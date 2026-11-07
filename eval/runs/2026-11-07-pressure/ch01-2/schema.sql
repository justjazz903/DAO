-- schema.sql : chat application, one long-term memory context per user.
-- Target: PostgreSQL 13+ (gen_random_uuid() is built in).
--
-- Layers
--   RAW, append-only. The application only INSERTs here. The single delete
--   path is account erasure, which starts at app_user and cascades.
--     app_user, user_message, user_file, generation, stop_press,
--     generation_end, erasure_request
--   DERIVED. Droppable and rebuildable from the layer beneath; every row
--   points at its sources by foreign key.
--     memory_note        (from generation: message, files, produced text)
--     memory_importance  (from memory_note)
--     views assistant_reply, generation_open (pure SQL over raw, no storage)
--
-- Column markers: [fact] recorded as it happened; [ref] key or external
-- reference; [derived] recomputable from other rows.

-- ---------------------------------------------------------------- RAW

-- An account exists. Owner: the user. Erasure = DELETE this row.
CREATE TABLE app_user (
  id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),  -- [fact]
  created_at timestamptz NOT NULL DEFAULT now()                  -- [fact]
);

-- One text the user sent to the assistant. Owner: the user.
CREATE TABLE user_message (
  id          bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id     uuid        NOT NULL REFERENCES app_user(id) ON DELETE CASCADE, -- [ref]
  body        text        NOT NULL,                     -- [fact] '' when only files were sent
  received_at timestamptz NOT NULL DEFAULT now()        -- [fact] server receipt time
);
CREATE INDEX user_message_user_recency ON user_message (user_id, received_at DESC);

-- One file sent with a message; the bytes live in object storage. Owner: the user.
CREATE TABLE user_file (
  id              bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_message_id bigint      NOT NULL REFERENCES user_message(id) ON DELETE CASCADE, -- [ref]
  storage_key     text        NOT NULL,  -- [ref] object-storage key; erasure deletes the object before the row
  media_type      text        NOT NULL,  -- [fact] MIME type as declared by the client (image/png, audio/mpeg, application/pdf, ...)
  byte_size       bigint      NOT NULL,  -- [fact]
  original_name   text        NOT NULL,  -- [fact] filename as the client supplied it
  uploaded_at     timestamptz NOT NULL DEFAULT now()  -- [fact]
);
CREATE INDEX user_file_message ON user_file (user_message_id);

-- One LLM invocation started in reply to a user message. Owner: the generation worker.
CREATE TABLE generation (
  id              bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_message_id bigint      NOT NULL REFERENCES user_message(id) ON DELETE CASCADE, -- [ref]
  model           text        NOT NULL,                 -- [fact] model identifier as sent to the provider
  started_at      timestamptz NOT NULL DEFAULT now()    -- [fact]
);
CREATE INDEX generation_message ON generation (user_message_id);

-- The user pressed Stop on a running generation. Owner: the user.
CREATE TABLE stop_press (
  generation_id bigint      NOT NULL REFERENCES generation(id) ON DELETE CASCADE, -- [ref]
  pressed_at    timestamptz NOT NULL DEFAULT now(),  -- [fact]
  PRIMARY KEY (generation_id, pressed_at)
);

-- The output stream closed, with whatever text had been produced. Absence = still running.
-- Owner: the generation worker.
CREATE TABLE generation_end (
  generation_id          bigint      PRIMARY KEY REFERENCES generation(id) ON DELETE CASCADE, -- [ref]
  ended_at               timestamptz NOT NULL DEFAULT now(),  -- [fact]
  body                   text        NOT NULL,  -- [fact] all text produced before the stream closed; partial after Stop
  provider_finish_reason text,                  -- [fact] verbatim from the provider; NULL when the worker closed the stream (Stop) or it failed
  error                  text                   -- [fact] error text when the stream failed; NULL otherwise
);

-- The user asked for all of their data to be erased. Owner: the user.
-- Fulfilled iff no app_user row with this id exists.
CREATE TABLE erasure_request (
  user_id      uuid        NOT NULL,  -- [fact] not a foreign key, so the row survives the cascade that fulfils it
  requested_at timestamptz NOT NULL DEFAULT now(),  -- [fact]
  PRIMARY KEY (user_id, requested_at)
);

-- ------------------------------------------------------------ DERIVED

-- A statement about the user drawn by the extractor from one exchange.
-- Rebuild: TRUNCATE, re-run extraction over generation. Owner: the memory extractor job.
CREATE TABLE memory_note (
  id            bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id       uuid        NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,    -- [ref] copied from the source exchange for indexing
  generation_id bigint      NOT NULL REFERENCES generation(id) ON DELETE CASCADE,  -- [ref] the exchange (message, files, produced text) it was derived from
  body          text        NOT NULL,                   -- [derived] the statement, in the extractor's words
  extractor     text        NOT NULL,                   -- [derived] extractor model + prompt version, so a rebuild is comparable
  extracted_at  timestamptz NOT NULL DEFAULT now()      -- [derived]
);
CREATE INDEX memory_note_user       ON memory_note (user_id);
CREATE INDEX memory_note_generation ON memory_note (generation_id);

-- The importance the context builder ranks notes by. A judgement: never source of
-- truth; DELETE and re-run the scorer at will. Owner: the scorer job.
CREATE TABLE memory_importance (
  memory_note_id bigint           PRIMARY KEY REFERENCES memory_note(id) ON DELETE CASCADE, -- [ref]
  user_id        uuid             NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,       -- [ref] copied for the ranking index
  score          double precision NOT NULL,                  -- [derived] higher is included first
  scorer         text             NOT NULL,                  -- [derived] scoring method + version
  scored_at      timestamptz      NOT NULL DEFAULT now()     -- [derived]
);
CREATE INDEX memory_importance_rank ON memory_importance (user_id, score DESC);

-- The reply shown in the thread: produced text plus whether Stop cut it short.
CREATE VIEW assistant_reply AS
SELECT g.id                       AS generation_id,
       g.user_message_id,
       m.user_id,
       e.body,
       e.ended_at,
       e.error,
       EXISTS (SELECT 1 FROM stop_press s WHERE s.generation_id = g.id) AS stopped  -- [derived]
FROM generation g
JOIN user_message   m ON m.id = g.user_message_id
JOIN generation_end e ON e.generation_id = g.id;

-- Generations whose stream has not closed: what the client shows as "working".
CREATE VIEW generation_open AS
SELECT g.id AS generation_id, g.user_message_id, m.user_id, g.model, g.started_at
FROM generation g
JOIN user_message m ON m.id = g.user_message_id
WHERE NOT EXISTS (SELECT 1 FROM generation_end e WHERE e.generation_id = g.id);
