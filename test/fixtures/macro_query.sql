-- name: GetAuthorByName :one
SELECT id, name, bio
FROM authors
WHERE name = sqlode.arg(author_name);

-- name: UpdateBio :exec
UPDATE authors
SET bio = sqlode.narg(new_bio)
WHERE id = sqlode.arg(author_id);
