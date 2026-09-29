-- name: GetAuthorsByAnySlice :many
SELECT id, name FROM authors WHERE id = ANY(sqlode.slice(ids));
