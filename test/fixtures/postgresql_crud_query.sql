-- name: GetAuthor :one
SELECT id, name, bio FROM authors WHERE id = $1;

-- name: ListAuthors :many
SELECT id, name, bio FROM authors ORDER BY name;

-- name: CreateAuthor :execlastid
INSERT INTO authors (name, bio) VALUES ($1, $2) RETURNING id;

-- name: DeleteAuthor :exec
DELETE FROM authors WHERE id = $1;

-- name: CountAuthors :one
SELECT COUNT(*) AS total FROM authors;

-- name: ListAuthorsWithSuccessor :many
SELECT a.name, s.name AS successor_name
FROM authors a LEFT JOIN authors s ON s.id = a.id + 1
ORDER BY a.id;

-- name: ListAuthorsByIds :many
SELECT id, name FROM authors WHERE id = ANY($1) ORDER BY id;
