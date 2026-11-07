-- schema.sql: chat application, one long-term memory context per user.
--
-- Layout: RAW tables first (append-only; each row is one thing that happened),
-- then DERIVED tables (rebuildable from the layer beneath; every row keys back
-- to its sources). Column tags: fact | ref | derived.
-- Erasure: DELETE FROM app_user WHERE id = $1 cascades through every table.

BEGIN;

-- ============================ RAW ============================

-- One row per account. Fact: "this user exists". Owner: the user.
CREATE TABLE app_user (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,  -- fact
  created_at  timestamptz NOT NULL DEFAULT now()                 -- fact
);

-- One row per message a user sent. Fact: "user U said text T at time S". Owner: the user.
CREATE TABLE user_message (
  id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,            -- fact
  user_id  bigint NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,  -- ref
  body     text NOT NULL,                                               -- fact
  sent_at  timestamptz NOT NULL DEFAULT now()                           -- fact
);
CREATE INDEX user_message_user_sent ON user_message (user_id, sent_at);

-- One row per file sent with a message. Fact: "message M carried this file". Owner: the user.
-- Bytes live in object storage; the row holds the key, never the bytes.
CREATE TABLE attachment (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,                -- fact
  user_message_id  bigint NOT NULL REFERENCES user_message(id) ON DELETE CASCADE,  -- ref
  storage_key      text NOT NULL UNIQUE,  -- fact: object-store key of the bytes
  file_name        text NOT NULL,         -- fact: name as sent by the client; replies refer to files by it
  media_type       text NOT NULL,         -- fact: MIME type as declared by the client
  byte_size        bigint NOT NULL        -- fact
);
CREATE INDEX attachment_message ON attachment (user_message_id);

-- One row per LLM invocation. Fact: "generation of the reply to message M started at T".
-- Owner: generation service. Exactly one invocation per user message.
CREATE TABLE reply (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,                       -- fact
  user_message_id  bigint NOT NULL UNIQUE REFERENCES user_message(id) ON DELETE CASCADE,  -- ref
  started_at       timestamptz NOT NULL DEFAULT now()                                      -- fact
);

-- One row per Stop press. Fact: "the user pressed Stop on reply R at T". Owner: the user.
CREATE TABLE reply_stop (
  reply_id    bigint PRIMARY KEY REFERENCES reply(id) ON DELETE CASCADE,  -- ref
  pressed_at  timestamptz NOT NULL DEFAULT now()                          -- fact
);

-- One row per reply whose generation has halted, whether it finished or was stopped.
-- Fact: "generation of R ended at T having produced text B". Owner: generation service.
-- A reply with no reply_end row is still being generated: that is the "working" state the client shows.
CREATE TABLE reply_end (
  reply_id  bigint PRIMARY KEY REFERENCES reply(id) ON DELETE CASCADE,  -- ref
  body      text NOT NULL,  -- fact: everything produced up to the halt; partial after a Stop, possibly empty
  ended_at  timestamptz NOT NULL DEFAULT now()                          -- fact
);

-- One row per erasure request. Fact: "user U asked for all their data to be erased at T". Owner: the user.
-- Fulfilled by deleting the attachment objects from object storage, then DELETE FROM app_user (cascade).
-- The request row is erased with everything else.
CREATE TABLE erasure_request (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,            -- fact
  user_id       bigint NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,  -- ref
  requested_at  timestamptz NOT NULL DEFAULT now()                          -- fact
);
CREATE INDEX erasure_request_user ON erasure_request (user_id);

-- ========================== DERIVED ==========================

-- One row per thing the assistant learned about a user from one exchange (user_message + reply_end).
-- Owner: memory extractor. Never updated: a later exchange that changes a fact yields a new note;
-- the earlier note stays. Truncate and re-extract from user_message/reply_end to rebuild.
CREATE TABLE memory_note (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,                -- derived
  user_id          bigint NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,      -- ref: same user as the source message; held here for the per-user index
  user_message_id  bigint NOT NULL REFERENCES user_message(id) ON DELETE CASCADE,  -- ref: the exchange this note was extracted from
  body             text NOT NULL,     -- derived: the note text as the extractor wrote it
  token_count      integer NOT NULL,  -- derived: tokens of body under the model's tokenizer; feeds the 8,000-token budget
  derived_at       timestamptz NOT NULL DEFAULT now()                               -- derived
);
CREATE INDEX memory_note_user ON memory_note (user_id);
CREATE INDEX memory_note_source ON memory_note (user_message_id);

-- One row per scored memory note. A judgement, not truth: truncate and recompute from memory_note at will.
-- Owner: importance scorer.
CREATE TABLE memory_note_importance (
  memory_note_id  bigint PRIMARY KEY REFERENCES memory_note(id) ON DELETE CASCADE,  -- ref
  score           real NOT NULL,  -- derived: higher is included first when the budget is tight
  scored_at       timestamptz NOT NULL DEFAULT now()                                 -- derived
);

COMMIT;
