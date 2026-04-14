-- name: BulkInsertPosts :copyfrom
INSERT INTO posts (title, body) VALUES (?1, ?2);
