-- Chat application schema. PostgreSQL 14+.
--
-- Raw layer (append-only): app_user, user_message, llm_invocation, llm_response.
-- Derived layer (droppable, rebuilt from raw): memory_note, user_transcript (view).
-- Column tags: [fact] recorded as it happened, [ref] reference to another row,
-- [derived] computed from raw rows.

-------------------------------------------------------------------------------
-- RAW LAYER
-------------------------------------------------------------------------------

-- Raw fact: a person registered with the application. Owner: the user.
create table app_user (
  id          bigint generated always as identity primary key,
  created_at  timestamptz not null default now()                 -- [fact]
);

-- Raw fact: a user submitted text to the assistant. Owner: the user.
create table user_message (
  id       bigint generated always as identity primary key,
  user_id  bigint not null references app_user (id),             -- [ref]
  body     text not null,                                        -- [fact]
  sent_at  timestamptz not null default now()                    -- [fact]
);
create index user_message_user_sent_idx on user_message (user_id, sent_at);

-- Raw fact: the application sent one request to the LLM for one user message.
-- Owner: the application. A retried message produces a second row.
create table llm_invocation (
  id               bigint generated always as identity primary key,
  user_message_id  bigint not null references user_message (id), -- [ref]
  model            text not null,                                -- [fact] provider model identifier used for this call
  prompt_input     jsonb not null,                               -- [fact] exact input sent: memory notes, transcript window and the new message as assembled at request time; a snapshot, never a reference to memory_note rows
  requested_at     timestamptz not null default now()            -- [fact]
);
create index llm_invocation_message_idx on llm_invocation (user_message_id);

-- Raw fact: the LLM answered one invocation. No row means no answer arrived.
-- Owner: the application.
create table llm_response (
  id             bigint generated always as identity primary key,
  invocation_id  bigint not null unique references llm_invocation (id), -- [ref]
  reply_text     text not null,                                  -- [fact] the assistant's reply as shown to the user
  received_at    timestamptz not null default now()              -- [fact]
);

-- Raw tables accept inserts only.
create function raw_is_append_only() returns trigger
language plpgsql as $$
begin
  raise exception 'table % is append-only', tg_table_name;
end
$$;

create trigger app_user_append_only
  before update or delete on app_user
  for each statement execute function raw_is_append_only();
create trigger user_message_append_only
  before update or delete on user_message
  for each statement execute function raw_is_append_only();
create trigger llm_invocation_append_only
  before update or delete on llm_invocation
  for each statement execute function raw_is_append_only();
create trigger llm_response_append_only
  before update or delete on llm_response
  for each statement execute function raw_is_append_only();

-------------------------------------------------------------------------------
-- DERIVED LAYER
-------------------------------------------------------------------------------

-- Derived: one statement the assistant learned about a user, extracted from one
-- exchange (invocation + response). Owner: the application. Rebuild by
-- truncating and re-running extraction over llm_invocation and llm_response.
create table memory_note (
  id             bigint generated always as identity primary key,
  user_id        bigint not null references app_user (id),       -- [ref] same user as invocation -> user_message; repeated here for the per-user read at prompt time
  invocation_id  bigint not null references llm_invocation (id), -- [ref] the raw exchange this note was extracted from
  content        text not null,                                  -- [derived] the learned statement, in prose
  derived_at     timestamptz not null default now()              -- [fact] when extraction ran
);
create index memory_note_user_idx on memory_note (user_id, id);

-- Derived: the chat history of a user, in time order. Not stored.
create view user_transcript as
  select m.user_id,
         m.sent_at          as at,
         'user'             as speaker,
         m.body             as text,
         m.id               as user_message_id,
         null::bigint       as llm_response_id
    from user_message m
  union all
  select m.user_id,
         r.received_at,
         'assistant',
         r.reply_text,
         m.id,
         r.id
    from llm_response r
    join llm_invocation i on i.id = r.invocation_id
    join user_message m   on m.id = i.user_message_id;
