-- name: CountAuthors :one
SELECT COUNT(*) AS total
FROM authors;

-- name: SumAndAvg :one
SELECT SUM(id) AS id_sum, AVG(id) AS id_avg
FROM authors;

-- name: CoalesceNullable :many
SELECT id, COALESCE(bio, 'N/A') AS bio_text
FROM authors;

-- name: CastColumn :many
SELECT id, CAST(name AS TEXT) AS name_text
FROM authors;

-- name: LiteralSelect :one
SELECT 1 AS one, 'hello' AS greeting
FROM authors;
