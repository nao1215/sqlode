-- Two well-typed queries, both under any realistic parameter limit.
-- name: GetAuthor :one
SELECT id, name FROM authors WHERE id = $1;

-- name: ListAuthors :many
SELECT id, name FROM authors ORDER BY name;
