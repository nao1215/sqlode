-- Fixture 4 for Issue #393: INSERT ... SELECT with a CTE input and
-- RETURNING. Exercises the expression-aware IR on prefixed CTEs for
-- non-SELECT statements, INSERT .. SELECT as an insert source, and
-- RETURNING column inference against the INSERT target.

-- name: CreateAuditRows :many
WITH changed_posts AS (
  SELECT p.id, p.user_id
  FROM posts AS p
  WHERE p.updated_at >= $1::timestamp
)
INSERT INTO audit_log (post_id, actor_id, action)
SELECT cp.id, cp.user_id, 'refresh'
FROM changed_posts AS cp
RETURNING id, post_id, actor_id, action;
