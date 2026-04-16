-- name: UpsertUser :one
INSERT INTO users (email, name)
VALUES ($1, $2)
ON CONFLICT (email) DO UPDATE SET name = EXCLUDED.name
RETURNING id, email, name;

-- name: ListPostsByTag :many
SELECT DISTINCT posts.id, posts.title
FROM posts
JOIN post_tags ON posts.id = post_tags.post_id
WHERE post_tags.tag_id = $1;

-- name: ListActiveUsers :many
SELECT user_id, COUNT(*) AS post_count
FROM posts
WHERE published = true
GROUP BY user_id
HAVING COUNT(*) > $1::int;

-- name: ListUsersWithPosts :many
SELECT id, name
FROM users
WHERE EXISTS (SELECT 1 FROM posts WHERE posts.user_id = users.id);

-- name: ListUsersWithoutPosts :many
SELECT id, name
FROM users
WHERE NOT EXISTS (SELECT 1 FROM posts WHERE posts.user_id = users.id);

-- name: PaginateUsers :many
SELECT id, name, email
FROM users
ORDER BY created_at DESC
LIMIT $1::int OFFSET $2::int;

-- name: RecentPostsWithAuthor :many
WITH recent AS (
  SELECT id, user_id, title FROM posts ORDER BY created_at DESC LIMIT 10
)
SELECT posts.id, posts.title, users.name
FROM posts
JOIN users ON posts.user_id = users.id
WHERE posts.id IN (SELECT id FROM recent);

-- name: TopDistinctScores :many
SELECT DISTINCT score
FROM users
ORDER BY score DESC
LIMIT $1::int;
