-- name: GetAuthor :one
SELECT `id`, `name` FROM `authors` WHERE `id` = ?;

-- name: CreateAuthor :exec
INSERT INTO `authors` (`name`, `bio`) VALUES (?, ?);

-- name: UpdateAuthor :exec
UPDATE `authors` SET `name` = ?, `bio` = ? WHERE `id` = ?;

-- name: ListAuthors :many
SELECT `id`, `name` FROM `authors` ORDER BY `name`;

-- name: DeleteAuthor :exec
DELETE FROM `authors` WHERE `id` = ?;
