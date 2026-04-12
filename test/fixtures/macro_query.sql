-- name: GetAuthorByName :one
SELECT id, name, bio
FROM authors
WHERE name = sqlc.arg(author_name);

-- name: UpdateBio :exec
UPDATE authors
SET bio = sqlc.narg(new_bio)
WHERE id = sqlc.arg(author_id);
