-- name: GetArticle :one
SELECT id, title, tags, scores
FROM articles
WHERE id = $1;

-- name: CreateArticle :exec
INSERT INTO articles (title, tags, scores) VALUES ($1, $2, $3);
