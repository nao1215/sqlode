-- name: GetUser :one
SELECT id, name, status FROM users WHERE id = $1;
