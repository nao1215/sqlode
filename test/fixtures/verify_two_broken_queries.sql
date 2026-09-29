-- Two queries that each select a column verify_ok_schema.sql does not have.
-- name: GetAuthorBio :one
SELECT id, bio FROM authors WHERE id = $1;

-- name: ListAuthorEmails :many
SELECT email FROM authors ORDER BY email;
