-- name: GetItem :one
SELECT id, external_id FROM items WHERE id = $1;
