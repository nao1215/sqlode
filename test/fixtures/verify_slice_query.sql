-- name: GetAuthorsByIds :many
SELECT id, name FROM authors WHERE id IN (sqlode.slice(ids));
