-- Chat application schema. PostgreSQL 13+ (gen_random_uuid is built in).
--
-- Layout: a raw layer of append-only fact tables, and a derived layer that is
-- views only. Views store nothing, so every derived value is recomputed from
-- the raw layer on read and can never drift from it.
--
-- Column convention: columns named *_id are references; content, model_name
-- and *_at columns are facts; no raw table holds a derived column.

-- ---------------------------------------------------------------------------
-- Raw layer
-- ---------------------------------------------------------------------------

CREATE TABLE app_user (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE app_user IS
    'Fact: an account exists. Owner: the user.';

CREATE TABLE user_message (
    id       uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id  uuid        NOT NULL REFERENCES app_user (id),
    content  text        NOT NULL,
    sent_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (id, user_id)   -- lets child rows prove they belong to the same user
);
COMMENT ON TABLE user_message IS
    'Fact: a user sent text to the assistant. Owner: the user.';
CREATE INDEX user_message_user_sent_idx ON user_message (user_id, sent_at);

CREATE TABLE llm_invocation (
    id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id          uuid        NOT NULL REFERENCES app_user (id),
    user_message_id  uuid        NOT NULL UNIQUE,
    model_name       text        NOT NULL,
    started_at       timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (user_message_id, user_id) REFERENCES user_message (id, user_id),
    UNIQUE (id, user_id)   -- lets child rows prove they belong to the same user
);
COMMENT ON TABLE llm_invocation IS
    'Fact: the model was called once, for one user, because of one message. Owner: the system.';
COMMENT ON COLUMN llm_invocation.user_message_id IS
    'The message that triggered this call. One call per message; UNIQUE enforces it.';
COMMENT ON COLUMN llm_invocation.model_name IS
    'The exact model identifier string sent to the provider.';
CREATE INDEX llm_invocation_user_started_idx ON llm_invocation (user_id, started_at);

CREATE TABLE assistant_message (
    id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    invocation_id  uuid        NOT NULL UNIQUE REFERENCES llm_invocation (id),
    content        text        NOT NULL,
    produced_at    timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE assistant_message IS
    'Fact: an invocation returned text to the user. Owner: the system. Absent when the call produced nothing.';

CREATE TABLE memory_note (
    id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id        uuid        NOT NULL REFERENCES app_user (id),
    invocation_id  uuid        NOT NULL,
    content        text        NOT NULL,
    asserted_at    timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (invocation_id, user_id) REFERENCES llm_invocation (id, user_id),
    UNIQUE (id, user_id)   -- lets child rows prove they belong to the same user
);
COMMENT ON TABLE memory_note IS
    'Fact: during an invocation the assistant stated something about the user to remember. Owner: the user.';
COMMENT ON COLUMN memory_note.content IS
    'The statement verbatim as the model emitted it. Never edited: a correction is a new note plus a retraction of this one.';
CREATE INDEX memory_note_user_asserted_idx ON memory_note (user_id, asserted_at);

CREATE TABLE memory_note_retraction (
    note_id        uuid        PRIMARY KEY,
    user_id        uuid        NOT NULL REFERENCES app_user (id),
    invocation_id  uuid        NOT NULL,
    retracted_at   timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (note_id, user_id)       REFERENCES memory_note (id, user_id),
    FOREIGN KEY (invocation_id, user_id) REFERENCES llm_invocation (id, user_id)
);
COMMENT ON TABLE memory_note_retraction IS
    'Fact: during an invocation the assistant stated that a note no longer holds. Owner: the user.';
COMMENT ON COLUMN memory_note_retraction.invocation_id IS
    'The call in which the retraction was made; must belong to the same user as the note.';

CREATE TABLE invocation_memory_input (
    invocation_id  uuid NOT NULL REFERENCES llm_invocation (id),
    note_id        uuid NOT NULL REFERENCES memory_note (id),
    PRIMARY KEY (invocation_id, note_id)
);
COMMENT ON TABLE invocation_memory_input IS
    'Fact: this note was placed in the context of this invocation. Owner: the system.';
CREATE INDEX invocation_memory_input_note_idx ON invocation_memory_input (note_id);

-- Raw tables are append-only. Enforced, not promised.
CREATE FUNCTION raw_is_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'table % is append-only', TG_TABLE_NAME;
END
$$;

CREATE TRIGGER app_user_append_only
    BEFORE UPDATE OR DELETE ON app_user
    FOR EACH STATEMENT EXECUTE FUNCTION raw_is_append_only();
CREATE TRIGGER user_message_append_only
    BEFORE UPDATE OR DELETE ON user_message
    FOR EACH STATEMENT EXECUTE FUNCTION raw_is_append_only();
CREATE TRIGGER llm_invocation_append_only
    BEFORE UPDATE OR DELETE ON llm_invocation
    FOR EACH STATEMENT EXECUTE FUNCTION raw_is_append_only();
CREATE TRIGGER assistant_message_append_only
    BEFORE UPDATE OR DELETE ON assistant_message
    FOR EACH STATEMENT EXECUTE FUNCTION raw_is_append_only();
CREATE TRIGGER memory_note_append_only
    BEFORE UPDATE OR DELETE ON memory_note
    FOR EACH STATEMENT EXECUTE FUNCTION raw_is_append_only();
CREATE TRIGGER memory_note_retraction_append_only
    BEFORE UPDATE OR DELETE ON memory_note_retraction
    FOR EACH STATEMENT EXECUTE FUNCTION raw_is_append_only();
CREATE TRIGGER invocation_memory_input_append_only
    BEFORE UPDATE OR DELETE ON invocation_memory_input
    FOR EACH STATEMENT EXECUTE FUNCTION raw_is_append_only();

-- ---------------------------------------------------------------------------
-- Derived layer (views only; nothing stored)
-- ---------------------------------------------------------------------------

CREATE VIEW current_memory AS
SELECT n.id            AS note_id,
       n.user_id,
       n.invocation_id AS asserted_by_invocation_id,
       n.content,
       n.asserted_at
FROM memory_note n
LEFT JOIN memory_note_retraction r ON r.note_id = n.id
WHERE r.note_id IS NULL;
COMMENT ON VIEW current_memory IS
    'Derived: notes with no retraction. This is what the next invocation for a user loads into its context.';

CREATE VIEW transcript AS
SELECT m.user_id,
       m.sent_at      AS occurred_at,
       'user_message' AS source_table,
       m.id           AS source_id,
       m.content
FROM user_message m
UNION ALL
SELECT i.user_id,
       a.produced_at,
       'assistant_message',
       a.id,
       a.content
FROM assistant_message a
JOIN llm_invocation i ON i.id = a.invocation_id;
COMMENT ON VIEW transcript IS
    'Derived: one user''s full history in time order; source_table and source_id point back at the raw row.';
