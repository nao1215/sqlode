-- name: CreateAuthor :exec
INSERT INTO authors (name, bio)
VALUES ($1, $2);
