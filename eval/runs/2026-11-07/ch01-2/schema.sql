-- Chat application: users talk to an LLM assistant inside one long-term memory context per user.
-- Two strands: schema "raw" is append-only facts; schema "derived" is rebuildable from "raw".
-- Column markers: fact = recorded as it happened; reference = points at another row; derived = recomputable.

CREATE SCHEMA raw;
CREATE SCHEMA derived;

-- Raises on any UPDATE or DELETE against a raw table. Raw is append-only.
CREATE FUNCTION raw.reject_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'raw.% is append-only (% refused)', TG_TABLE_NAME, TG_OP;
END
$$;

------------------------------------------------------------------------------
-- RAW LAYER
------------------------------------------------------------------------------

-- Fact: a user account came into existence. Owner: the application.
CREATE TABLE raw.users (
    id         bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY, -- fact
    created_at timestamptz NOT NULL DEFAULT now()                    -- fact
);

-- Fact: a user submitted text to the assistant. Owner: the user.
CREATE TABLE raw.user_messages (
    id      bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY, -- fact
    user_id bigint      NOT NULL REFERENCES raw.users (id),       -- reference
    body    text        NOT NULL,                                 -- fact
    sent_at timestamptz NOT NULL DEFAULT now()                    -- fact
);
CREATE INDEX user_messages_user_sent_idx ON raw.user_messages (user_id, sent_at);

-- Fact: the application sent one request to the LLM in reply to one user message. Owner: the application.
CREATE TABLE raw.llm_invocations (
    id              bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY, -- fact
    user_message_id bigint      NOT NULL REFERENCES raw.user_messages (id), -- reference
    model           text        NOT NULL,                                 -- fact
    request         jsonb       NOT NULL,                                 -- fact
    started_at      timestamptz NOT NULL DEFAULT now()                    -- fact
);
COMMENT ON COLUMN raw.llm_invocations.request IS
    'The exact request body sent to the provider, including whatever memory text and prior messages were included at that moment. Stored as text, never as references to derived rows, so raw does not depend on derived.';
CREATE INDEX llm_invocations_user_message_idx ON raw.llm_invocations (user_message_id);

-- Fact: the LLM returned a reply to an invocation. Owner: the LLM provider.
CREATE TABLE raw.assistant_messages (
    id            bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,         -- fact
    invocation_id bigint      NOT NULL UNIQUE REFERENCES raw.llm_invocations (id), -- reference
    body          text        NOT NULL,                                         -- fact
    received_at   timestamptz NOT NULL DEFAULT now()                            -- fact
);

-- Fact: an invocation ended without a reply. Owner: the application. A retry is a new invocation.
CREATE TABLE raw.llm_invocation_failures (
    id            bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,         -- fact
    invocation_id bigint      NOT NULL UNIQUE REFERENCES raw.llm_invocations (id), -- reference
    error         text        NOT NULL,                                         -- fact
    failed_at     timestamptz NOT NULL DEFAULT now()                            -- fact
);

CREATE TRIGGER append_only BEFORE UPDATE OR DELETE ON raw.users
    FOR EACH ROW EXECUTE FUNCTION raw.reject_mutation();
CREATE TRIGGER append_only BEFORE UPDATE OR DELETE ON raw.user_messages
    FOR EACH ROW EXECUTE FUNCTION raw.reject_mutation();
CREATE TRIGGER append_only BEFORE UPDATE OR DELETE ON raw.llm_invocations
    FOR EACH ROW EXECUTE FUNCTION raw.reject_mutation();
CREATE TRIGGER append_only BEFORE UPDATE OR DELETE ON raw.assistant_messages
    FOR EACH ROW EXECUTE FUNCTION raw.reject_mutation();
CREATE TRIGGER append_only BEFORE UPDATE OR DELETE ON raw.llm_invocation_failures
    FOR EACH ROW EXECUTE FUNCTION raw.reject_mutation();

------------------------------------------------------------------------------
-- DERIVED LAYER (drop and rebuild: TRUNCATE, then re-run extraction over raw.user_messages in sent_at order)
------------------------------------------------------------------------------

-- Derived: one statement the assistant learned about a user, extracted from one user message. Owner: the application.
CREATE TABLE derived.memory_items (
    id              bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,   -- derived
    user_id         bigint      NOT NULL REFERENCES raw.users (id),         -- reference (copied from the source message for the read path)
    user_message_id bigint      NOT NULL REFERENCES raw.user_messages (id), -- reference
    content         text        NOT NULL,                                   -- derived
    extractor_model text        NOT NULL,                                   -- derived
    extracted_at    timestamptz NOT NULL DEFAULT now()                      -- derived
);
COMMENT ON COLUMN derived.memory_items.user_message_id IS
    'The raw message this statement was extracted from. Every memory item points at its evidence.';
COMMENT ON COLUMN derived.memory_items.content IS
    'The learned statement in prose, as it is placed into the request of every later invocation for this user.';
COMMENT ON COLUMN derived.memory_items.extractor_model IS
    'Provenance: the model that produced content. Lets a rebuild tell old extractions from new ones.';
CREATE INDEX memory_items_user_extracted_idx ON derived.memory_items (user_id, extracted_at);
