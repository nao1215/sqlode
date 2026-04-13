-- name: GetBookWithAuthorIds :one
SELECT authors.id, books.id, books.title FROM books JOIN authors ON books.author_id = authors.id WHERE books.id = $1;
