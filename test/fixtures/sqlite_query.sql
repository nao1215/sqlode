-- name: GetAuthorById :one
SELECT id, name FROM authors WHERE id = ?1;

-- name: GetAuthorByName :one
SELECT id, name FROM authors WHERE name = :name;

-- name: GetAuthorByEmail :one
SELECT id, name FROM authors WHERE name = @author_name;

-- name: GetAuthorBySlug :one
SELECT id, name FROM authors WHERE name = $slug;

-- name: CreateAuthor :exec
INSERT INTO authors (name, bio) VALUES (?1, ?2);

-- name: ListAuthors :many
SELECT id, name FROM authors ORDER BY name;
