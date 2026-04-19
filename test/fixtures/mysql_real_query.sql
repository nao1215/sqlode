-- name: CreateAuthor :execlastid
INSERT INTO authors (email, display_name, bio, is_active, avatar)
VALUES (?, ?, ?, ?, ?);

-- name: GetAuthor :one
SELECT id, email, display_name, bio, is_active, avatar
FROM authors
WHERE id = ?;

-- name: ListAuthors :many
SELECT id, email, display_name
FROM authors
ORDER BY id;

-- name: UpdateAuthorBio :execrows
UPDATE authors
SET bio = ?
WHERE id = ?;

-- name: DeleteAuthor :exec
DELETE FROM authors
WHERE id = ?;

-- name: UpsertAuthor :execrows
INSERT INTO authors (email, display_name, bio, is_active, avatar)
VALUES (?, ?, ?, ?, ?)
ON DUPLICATE KEY UPDATE
  display_name = VALUES(display_name),
  bio = VALUES(bio);
