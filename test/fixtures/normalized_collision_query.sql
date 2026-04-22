-- Two distinct annotation names that both normalize to the
-- snake_case identifier `get_user`, which would produce
-- duplicate declarations for get_user / GetUserRow / GetUserParams /
-- prepare_get_user / get_user_decoder if generation proceeded.
-- name: GetUser :one
SELECT id, name FROM authors WHERE id = $1;

-- name: get_user :one
SELECT id, name FROM authors WHERE name = $1;
