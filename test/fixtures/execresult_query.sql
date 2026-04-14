-- name: UpdatePost :execresult
UPDATE posts SET title = ?1 WHERE id = ?2;
