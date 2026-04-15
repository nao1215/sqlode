-- name: SearchByNameOrBio :many
SELECT id, name, bio
FROM authors
WHERE name = sqlode.arg(search_term) OR bio LIKE sqlode.arg(search_term);

-- name: InsertWithMixedMacros :exec
INSERT INTO authors (name, bio)
VALUES (sqlode.arg(author_name), sqlode.narg(author_bio));

-- name: GetByMultipleIds :many
SELECT id, name FROM authors WHERE id IN (sqlode.slice(ids));

-- name: UpdateWithNarg :exec
UPDATE authors SET name = sqlode.arg(new_name), bio = sqlode.narg(new_bio) WHERE id = sqlode.arg(author_id);
