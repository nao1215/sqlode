-- name: GetPost :one
SELECT id, title, body FROM posts WHERE id = ?1;

-- name: ListPosts :many
SELECT id, title FROM posts ORDER BY id;

-- name: CreatePost :exec
INSERT INTO posts (title, body) VALUES (?1, ?2);

-- name: UpdatePost :execresult
UPDATE posts SET title = ?1, body = ?2 WHERE id = ?3;

-- name: CountPosts :execrows
SELECT id FROM posts;

-- name: InsertPost :execlastid
INSERT INTO posts (title, body) VALUES (?1, ?2);

-- name: GetPostBatch :batchone
SELECT id, title, body FROM posts WHERE id = ?1;

-- name: ListPostsBatch :batchmany
SELECT id, title FROM posts WHERE id = ?1;

-- name: CreatePostBatch :batchexec
INSERT INTO posts (title, body) VALUES (?1, ?2);
