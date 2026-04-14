-- name: CreatePostBatch :batchexec
INSERT INTO posts (title, body) VALUES (?1, ?2);
