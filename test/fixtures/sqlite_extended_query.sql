-- name: CreateAuthor :exec
INSERT INTO authors (name, bio) VALUES (?1, ?2);

-- name: InsertAuthor :execlastid
INSERT INTO authors (name, bio) VALUES (?1, ?2);

-- name: UpdateAuthorBio :execrows
UPDATE authors SET bio = ?1 WHERE id = ?2;

-- name: UpdateBioNullable :exec
UPDATE authors SET bio = sqlc.narg(new_bio) WHERE id = sqlc.arg(author_id);

-- name: GetAuthorsByIds :many
SELECT id, name, bio FROM authors WHERE id IN (sqlc.slice(ids));

-- name: CreatePost :exec
INSERT INTO posts (title, body, author_id) VALUES (?1, ?2, ?3);

-- name: GetPostWithAuthor :one
SELECT posts.id, posts.title, posts.body, authors.name
FROM posts JOIN authors ON posts.author_id = authors.id
WHERE posts.id = ?1;

-- name: GetAuthorsByIdsAndNames :many
SELECT id, name, bio FROM authors WHERE id IN (sqlc.slice(ids)) AND name IN (sqlc.slice(names));

-- name: ListAuthors :many
SELECT id, name, bio FROM authors ORDER BY name;
