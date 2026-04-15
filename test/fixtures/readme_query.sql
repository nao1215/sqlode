-- name: GetAuthor :one
SELECT id, name
FROM authors
WHERE id = $1;

-- name: ListAuthors :many
SELECT id, name
FROM authors
ORDER BY name;

-- name: CreateAuthor :exec
INSERT INTO authors (name, bio) VALUES ($1, $2);

-- name: GetAuthorsByIds :many
SELECT id, name FROM authors
WHERE id IN (sqlc.slice(ids));

-- name: GetBookWithAuthor :one
SELECT sqlc.embed(authors), books.title
FROM books
JOIN authors ON books.author_id = authors.id
WHERE books.id = $1;
