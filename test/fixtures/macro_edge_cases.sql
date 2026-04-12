-- name: SearchByNameOrBio :many
SELECT id, name, bio
FROM authors
WHERE name = sqlc.arg(search_term) OR bio LIKE sqlc.arg(search_term);

-- name: InsertWithMixedMacros :exec
INSERT INTO authors (name, bio)
VALUES (sqlc.arg(author_name), sqlc.narg(author_bio));

-- name: GetByMultipleIds :many
SELECT id, name FROM authors WHERE id IN (sqlc.slice(ids));

-- name: UpdateWithNarg :exec
UPDATE authors SET name = sqlc.arg(new_name), bio = sqlc.narg(new_bio) WHERE id = sqlc.arg(author_id);
