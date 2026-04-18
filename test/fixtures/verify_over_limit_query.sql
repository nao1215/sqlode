-- Query with three parameters — used to exercise the
-- query_parameter_limit policy in sqlode verify.
-- name: FilterAuthors :many
SELECT id, name
FROM authors
WHERE id = $1 AND name = $2 AND id = $3;
