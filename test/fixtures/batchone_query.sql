-- name: GetPostBatch :batchone
SELECT id, title, body FROM posts WHERE id = ?1;
