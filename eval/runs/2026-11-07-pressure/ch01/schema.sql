-- schema.sql — chat application: one long-term memory context per user.
-- Target: PostgreSQL 16.
--
-- Two layers.
--   RAW     : facts recorded as they happened. Rows are only inserted. The only
--             deletion is erasure, by cascade from app_user, at the user's request.
--   DERIVED : values computed from the layer beneath. Any DERIVED table may be
--             truncated and rebuilt from RAW; RAW is never written by derivation.
--
-- Column convention (so each column need not repeat it): a *_id column that is
-- not the whole primary key is a reference; every column in a DERIVED table is
-- a derived value; every other column is a fact.

BEGIN;

------------------------------------------------------------------------------
-- RAW
------------------------------------------------------------------------------

-- An account exists. Owner: the user. Deleting the row is erasure.
CREATE TABLE app_user (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- The user sent a message. Owner: the user.
CREATE TABLE user_message (
  id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id  bigint NOT NULL REFERENCES app_user (id) ON DELETE CASCADE,
  sent_at  timestamptz NOT NULL DEFAULT now(),
  text     text NOT NULL
);
CREATE INDEX user_message_user_sent ON user_message (user_id, sent_at);

-- The user attached a file to a message. Owner: the user.
CREATE TABLE attachment (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_message_id  bigint NOT NULL REFERENCES user_message (id) ON DELETE CASCADE,
  storage_key      text   NOT NULL,  -- key of the bytes in the object store; erasure deletes the object before the row
  media_type       text   NOT NULL,  -- as declared by the client, e.g. image/png, audio/mpeg, application/pdf
  byte_size        bigint NOT NULL,
  file_name        text   NOT NULL   -- original name on the client's device
);
CREATE INDEX attachment_message ON attachment (user_message_id);

-- The application called the model for a user message. Owner: the system.
-- "Assistant is working" = an invocation with no assistant_reply row yet.
CREATE TABLE invocation (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_message_id  bigint NOT NULL UNIQUE REFERENCES user_message (id) ON DELETE CASCADE,
  started_at       timestamptz NOT NULL DEFAULT now()
);

-- The user pressed Stop while an invocation was generating. Owner: the user.
CREATE TABLE stop_request (
  invocation_id  bigint PRIMARY KEY REFERENCES invocation (id) ON DELETE CASCADE,
  requested_at   timestamptz NOT NULL DEFAULT now()
);

-- Generation halted; this is the text produced by then. Owner: the system.
-- Whether it halted because the model finished or because of Stop is read from stop_request.
CREATE TABLE assistant_reply (
  invocation_id  bigint PRIMARY KEY REFERENCES invocation (id) ON DELETE CASCADE,
  halted_at      timestamptz NOT NULL DEFAULT now(),
  text           text NOT NULL   -- everything produced up to the halt; may be partial
);

-- The user asked for all their data to be erased. Owner: the user.
-- Pending = the referenced app_user still exists. Execution is
-- DELETE FROM app_user WHERE id = user_id, which cascades through every table,
-- this one included; by requirement nothing remains afterwards.
CREATE TABLE erasure_request (
  user_id       bigint PRIMARY KEY REFERENCES app_user (id) ON DELETE CASCADE,
  requested_at  timestamptz NOT NULL DEFAULT now()
);

------------------------------------------------------------------------------
-- DERIVED
------------------------------------------------------------------------------

-- Text rendering of one attachment (OCR, transcript, caption) so it can be
-- counted against the token budget. Derived from attachment. Owner: the system.
CREATE TABLE attachment_text (
  attachment_id  bigint PRIMARY KEY REFERENCES attachment (id) ON DELETE CASCADE,
  text           text    NOT NULL,
  token_count    integer NOT NULL,  -- length of text under the model's tokenizer
  derived_at     timestamptz NOT NULL DEFAULT now()
);

-- One thing the assistant learned about a user, extracted from that user's
-- messages (and the attachments and replies hanging off them). Owner: the system.
CREATE TABLE memory_note (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id      bigint NOT NULL REFERENCES app_user (id) ON DELETE CASCADE,
  text         text    NOT NULL,
  token_count  integer NOT NULL,  -- length of text under the model's tokenizer
  derived_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX memory_note_user ON memory_note (user_id);

-- Which raw messages a memory note was extracted from. Owner: the system.
CREATE TABLE memory_note_source (
  memory_note_id   bigint NOT NULL REFERENCES memory_note (id) ON DELETE CASCADE,
  user_message_id  bigint NOT NULL REFERENCES user_message (id) ON DELETE CASCADE,
  PRIMARY KEY (memory_note_id, user_message_id)
);
CREATE INDEX memory_note_source_message ON memory_note_source (user_message_id);

-- A judgement of how important a note is, used only to rank notes into the
-- 8,000-token context. Derived from memory_note and its sources. Owner: the
-- system. Never source of truth: drop and rescore at will.
CREATE TABLE memory_note_importance (
  memory_note_id  bigint PRIMARY KEY REFERENCES memory_note (id) ON DELETE CASCADE,
  importance      real NOT NULL,   -- higher is preferred; the scale belongs to the scorer that wrote it
  scored_at       timestamptz NOT NULL DEFAULT now()
);

COMMIT;
