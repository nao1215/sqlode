-- Fixture 2 for Issue #393: LATERAL subquery + aggregate projection.
-- Exercises the expression-aware IR on LATERAL joins, correlated
-- access to outer columns (`p.team_id = t.id`), COALESCE and the
-- `sqlode.slice` macro used inside an ANY(...) comparison.

-- name: ListTeamsWithLatestPost :many
SELECT
  t.id,
  t.name,
  latest_post.created_at AS latest_post_at,
  COALESCE(stats.member_count, 0) AS member_count
FROM teams AS t
LEFT JOIN LATERAL (
  SELECT p.created_at
  FROM posts AS p
  WHERE p.team_id = t.id
  ORDER BY p.created_at DESC
  LIMIT 1
) AS latest_post ON TRUE
LEFT JOIN (
  SELECT m.team_id, COUNT(*) AS member_count
  FROM memberships AS m
  GROUP BY m.team_id
) AS stats ON stats.team_id = t.id
WHERE t.id = ANY(sqlode.slice(team_ids));
