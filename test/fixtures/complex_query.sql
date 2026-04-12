-- name: GetPost :one
SELECT id, title, body, published
FROM posts
WHERE id = $1;

-- name: ListPostsByAuthor :many
SELECT id, title, published, view_count
FROM posts
WHERE author_id = $1
ORDER BY created_at;

-- name: CreatePost :exec
INSERT INTO posts (title, body, author_id, category_id, published, view_count, rating, created_at)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8);

-- name: UpdatePostTitle :exec
UPDATE posts SET title = $1 WHERE id = $2;

-- name: DeletePost :exec
DELETE FROM posts WHERE id = $1;

-- name: GetPostWithAuthor :one
SELECT posts.title, users.username
FROM posts
JOIN users ON posts.author_id = users.id
WHERE posts.id = $1;

-- name: GetPostWithAuthorAndCategory :one
SELECT posts.title, users.username, categories.name
FROM posts
JOIN users ON posts.author_id = users.id
JOIN categories ON posts.category_id = categories.id
WHERE posts.id = $1;

-- name: ListCommentsForPost :many
SELECT comments.id, comments.body, users.username
FROM comments
JOIN users ON comments.author_id = users.id
WHERE comments.post_id = $1
ORDER BY comments.created_at;

-- name: CountPostsByAuthor :one
SELECT id FROM posts WHERE author_id = $1;

-- name: CreatePostReturning :one
INSERT INTO posts (title, body, author_id, published, view_count, created_at)
VALUES ($1, $2, $3, $4, $5, $6)
RETURNING id, title;

-- name: DeletePostReturning :one
DELETE FROM posts WHERE id = $1
RETURNING id, title;

-- name: UpdatePostReturning :one
UPDATE posts SET title = $1 WHERE id = $2
RETURNING id, title, published;
