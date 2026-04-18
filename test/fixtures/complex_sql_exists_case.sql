-- Fixture 3 for Issue #393: correlated EXISTS + nested CASE +
-- nullable branches. Exercises EXISTS as a boolean predicate inside
-- a WHEN branch, a CASE that can project NULL, and arithmetic that
-- mixes a non-nullable column with a casted parameter.

-- name: ListReviewablePosts :many
SELECT
  p.id,
  CASE
    WHEN EXISTS (
      SELECT 1
      FROM comments AS c
      WHERE c.post_id = p.id AND c.flagged = TRUE
    ) THEN 'flagged'
    WHEN p.deleted_at IS NOT NULL THEN 'deleted'
    ELSE 'clean'
  END AS moderation_state,
  CASE
    WHEN p.reviewed_at IS NOT NULL THEN p.reviewed_at
    ELSE NULL
  END AS review_timestamp
FROM posts AS p
WHERE (p.score + $1::int) > $2::int;
