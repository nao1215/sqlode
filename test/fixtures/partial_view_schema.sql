-- Schema fixture for Issue #391: a view with one intentionally
-- unresolved column (`missing_source.value`) — sqlode must refuse
-- to produce a partial catalog from this schema by default.

CREATE TABLE users (
  id BIGINT PRIMARY KEY NOT NULL,
  email TEXT NOT NULL
);

CREATE TABLE posts (
  id BIGINT PRIMARY KEY NOT NULL,
  user_id BIGINT NOT NULL,
  created_at TIMESTAMP NOT NULL,
  published BOOL NOT NULL
);

CREATE VIEW user_rollups AS
SELECT
  u.id,
  COALESCE(pub_counts.published_posts, 0) AS published_posts,
  latest_post.created_at AS latest_post_at,
  missing_source.value AS broken_col
FROM users AS u
LEFT JOIN (
  SELECT p.user_id, COUNT(*) AS published_posts
  FROM posts AS p
  WHERE p.published = TRUE
  GROUP BY p.user_id
) AS pub_counts ON pub_counts.user_id = u.id
LEFT JOIN LATERAL (
  SELECT p.created_at
  FROM posts AS p
  WHERE p.user_id = u.id
  ORDER BY p.created_at DESC
  LIMIT 1
) AS latest_post ON TRUE;
