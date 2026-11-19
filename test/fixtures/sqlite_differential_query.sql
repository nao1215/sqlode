-- Queries for scripts/differential_sqlite.py, run against
-- sqlite_advanced_schema.sql. Each one has a shape where the parameter
-- count or the result columns are easy to get wrong.

-- name: SameNameTwice :many
SELECT id, name FROM authors WHERE name = :name OR bio = :name;

-- name: BareQuestionMarks :many
SELECT id FROM authors WHERE name = ? AND id > ?;

-- name: NumberedReused :many
SELECT id FROM authors WHERE name = ?1 OR bio = ?1;

-- name: StarJoin :many
SELECT * FROM authors a JOIN posts p ON p.author_id = a.id;

-- name: CountWithAlias :one
SELECT COUNT(*) AS total FROM authors;

-- name: ScalarSubquery :many
SELECT id, (SELECT COUNT(*) FROM posts WHERE posts.author_id = authors.id) AS post_count FROM authors;

-- name: CteReordered :many
WITH named AS (SELECT id, name FROM authors) SELECT name, id FROM named;

-- name: UnionTitles :many
SELECT name AS label FROM authors UNION ALL SELECT title FROM posts;

-- name: QuotedColumn :many
SELECT "name" FROM authors;

-- name: InsertReturning :one
INSERT INTO authors (name, bio) VALUES (?, ?) RETURNING id, name;

-- name: UpdateReturning :one
UPDATE posts SET title = ?1 WHERE id = ?2 RETURNING id, title, author_id;

-- name: DeleteReturning :one
DELETE FROM posts WHERE author_id = ? RETURNING id;

-- name: LimitOffset :many
SELECT id, title FROM posts ORDER BY id LIMIT ? OFFSET ?;

-- name: InList :many
SELECT id FROM posts WHERE author_id IN (?, ?, ?);

-- name: CaseExpression :many
SELECT id, CASE WHEN bio IS NULL THEN 'none' ELSE bio END AS bio_text FROM authors WHERE name LIKE ?;

-- name: ColonInLiteral :many
SELECT id FROM authors WHERE name = ':not_a_param' AND bio = :bio;
