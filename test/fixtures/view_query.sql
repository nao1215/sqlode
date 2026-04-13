-- name: GetActiveAuthor :one
SELECT id, name FROM active_authors WHERE id = ?1;

-- name: ListFullAuthors :many
SELECT id, name, bio FROM full_authors;
