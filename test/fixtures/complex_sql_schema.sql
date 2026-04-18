-- Schema backing the four complex SQL fixtures for Issue #393.
-- Each column is annotated so the analyzer can distinguish nullable
-- from NOT NULL references, which in turn shapes the inferred
-- `nullable` flag on the generated result columns.

CREATE TABLE users (
  id BIGINT PRIMARY KEY NOT NULL,
  email TEXT NOT NULL
);

CREATE TABLE posts (
  id BIGINT PRIMARY KEY NOT NULL,
  user_id BIGINT NOT NULL,
  team_id BIGINT NOT NULL,
  score INTEGER NOT NULL,
  created_at TIMESTAMP NOT NULL,
  updated_at TIMESTAMP NOT NULL,
  reviewed_at TIMESTAMP,
  deleted_at TIMESTAMP
);

CREATE TABLE teams (
  id BIGINT PRIMARY KEY NOT NULL,
  name TEXT NOT NULL
);

CREATE TABLE memberships (
  team_id BIGINT NOT NULL,
  user_id BIGINT NOT NULL
);

CREATE TABLE comments (
  id BIGINT PRIMARY KEY NOT NULL,
  post_id BIGINT NOT NULL,
  flagged BOOLEAN NOT NULL
);

CREATE TABLE audit_log (
  id BIGINT PRIMARY KEY NOT NULL,
  post_id BIGINT NOT NULL,
  actor_id BIGINT NOT NULL,
  action TEXT NOT NULL
);
