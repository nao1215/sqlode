-- name: GetAuthor :one
SELECT id, name FROM authors WHERE id = $1;

-- name: ListAuthors :many
SELECT id, name FROM authors;

-- name: GetAuthor :one
SELECT id, name FROM authors WHERE name = $1;
