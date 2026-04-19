-- name: SearchAuthors :many
SELECT `id`, `name`
FROM `authors`
WHERE `name` LIKE sqlode.arg(pattern)
ORDER BY `id`
LIMIT 20, 10;

-- name: GetByIds :many
SELECT `id`, `name`
FROM `authors`
WHERE `id` IN (sqlode.slice(ids))
ORDER BY `id`;

-- name: UpsertAuthor :execrows
INSERT INTO `authors` (`email`, `name`, `bio`)
VALUES (?, ?, ?)
ON DUPLICATE KEY UPDATE
  `name` = VALUES(`name`),
  `bio` = VALUES(`bio`);

-- name: ListAuthorPosts :many
WITH active_authors AS (
  SELECT `id`, `name`
  FROM `authors`
  WHERE `is_active` = TRUE
)
SELECT a.`id`, a.`name`, p.`title`
FROM active_authors AS a
JOIN `posts` AS p ON p.`author_id` = a.`id`
WHERE p.`published` = ?
ORDER BY p.`id`;
