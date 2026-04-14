-- name: ListPostsBatch :batchmany
SELECT id, title FROM posts WHERE id = ?1;
