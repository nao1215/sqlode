-- Schema backing the ambiguous-parameter regression fixture for
-- Issue #390. The shape mirrors the reproduction in the issue:
-- three tables that all expose an `id` column so an unqualified
-- `WHERE id = $1` predicate is ambiguous.

CREATE TABLE users (
  id BIGINT PRIMARY KEY NOT NULL,
  team_id BIGINT NOT NULL,
  deleted_at TIMESTAMP
);

CREATE TABLE teams (
  id BIGINT PRIMARY KEY NOT NULL,
  owner_id BIGINT NOT NULL
);

CREATE TABLE memberships (
  id BIGINT PRIMARY KEY NOT NULL,
  user_id BIGINT NOT NULL,
  team_id BIGINT NOT NULL
);
