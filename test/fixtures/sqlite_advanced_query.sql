-- name: CreateAuthor :exec
INSERT INTO authors (name, bio) VALUES (?1, ?2);

-- name: CreatePost :exec
INSERT INTO posts (title, body, author_id) VALUES (?1, ?2, ?3);

-- name: CountAuthors :one
SELECT COUNT(*) AS total FROM authors;

-- name: CoalesceAuthorBio :many
SELECT id, COALESCE(bio, 'N/A') AS bio_text FROM authors;

-- name: GetPostWithAuthorLeftJoin :one
SELECT posts.id, posts.title, authors.name AS author_name
FROM posts
LEFT JOIN authors ON posts.author_id = authors.id
WHERE posts.id = ?1;

-- name: ListAuthors :many
SELECT id, name, bio FROM authors ORDER BY name;

-- name: GetPostWithAuthorEmbed :one
SELECT sqlode.embed(authors), posts.title
FROM posts
JOIN authors ON posts.author_id = authors.id
WHERE posts.id = ?1;
