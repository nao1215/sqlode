-- name: GetAuthor :one
SELECT id, name
FROM authors
WHERE id = $1;
