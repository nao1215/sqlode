-- Regression fixture for Issue #390. The unqualified `WHERE id = $1`
-- appears after a CTE + join that exposes `id` on three tables:
-- `memberships`, `active_users` (from the CTE), and `teams`.
-- Parameter inference must refuse to pick one silently.

-- name: GetMembership :one
WITH active_users AS (
  SELECT u.id, u.team_id
  FROM users AS u
  WHERE u.deleted_at IS NULL
)
SELECT m.id, t.owner_id
FROM memberships AS m
JOIN active_users AS au ON au.id = m.user_id
JOIN teams AS t ON t.id = au.team_id
WHERE id = $1;
