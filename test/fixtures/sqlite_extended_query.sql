-- name: CreateAuthor :exec
INSERT INTO authors (name, bio) VALUES (?1, ?2);

-- name: InsertAuthor :execlastid
INSERT INTO authors (name, bio) VALUES (?1, ?2);

-- name: UpdateAuthorBio :execrows
UPDATE authors SET bio = ?1 WHERE id = ?2;

-- name: UpdateBioNullable :exec
UPDATE authors SET bio = sqlode.narg(new_bio) WHERE id = sqlode.arg(author_id);

-- sqlode.slice() is rejected on SQLite as of v0.19.0 (PR #533): the
-- sqlight adapter cannot bind array values at runtime. The previous
-- GetAuthorsByIds / GetAuthorsByIdsAndNames queries that exercised
-- IN-clause expansion via sqlode.slice() were removed from this
-- SQLite-engine fixture for that reason. The slice macro stays
-- supported on PostgreSQL and is regression-tested by
-- verify_test.gleam:verify_allows_slice_macro_on_postgresql_test.

-- name: CreatePost :exec
INSERT INTO posts (title, body, author_id) VALUES (?1, ?2, ?3);

-- name: GetPostWithAuthor :one
SELECT posts.id, posts.title, posts.body, authors.name
FROM posts JOIN authors ON posts.author_id = authors.id
WHERE posts.id = ?1;

-- name: ListAuthors :many
SELECT id, name, bio FROM authors ORDER BY name;
