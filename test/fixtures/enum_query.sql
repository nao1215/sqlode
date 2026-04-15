-- name: GetUser :one
SELECT id, name, status FROM users WHERE id = $1;

-- name: ListUsersByStatuses :many
SELECT id, name, status FROM users WHERE status IN (sqlode.slice(statuses));
