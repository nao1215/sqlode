-- name: GetUserByUuid :one
SELECT id, name FROM users WHERE id = $1::int;

-- name: CreateUserWithUuid :exec
INSERT INTO users (name, metadata) VALUES ($1::text, $2::jsonb);
