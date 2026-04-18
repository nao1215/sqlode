-- Fixture 1 for Issue #393: CTE + window + CASE + arithmetic.
-- Exercises the expression-aware IR on nested CTE references,
-- window expressions, CASE branches and arithmetic with casts.

-- name: ListRankedUsers :many
WITH ranked_posts AS (
  SELECT
    p.user_id,
    COUNT(*) AS post_count,
    ROW_NUMBER() OVER (
      PARTITION BY p.user_id
      ORDER BY MAX(p.created_at) DESC
    ) AS post_rank
  FROM posts AS p
  WHERE p.created_at >= $1::timestamp
  GROUP BY p.user_id
),
scored_users AS (
  SELECT
    u.id,
    u.email,
    rp.post_count,
    CASE
      WHEN rp.post_count >= 100 THEN 'power'
      WHEN rp.post_count >= 10 THEN 'active'
      ELSE 'casual'
    END AS tier,
    (rp.post_count * 2) + $2::int AS score
  FROM users AS u
  JOIN ranked_posts AS rp ON rp.user_id = u.id
)
SELECT id, email, tier, score
FROM scored_users
WHERE score > $3::int
ORDER BY score DESC;
