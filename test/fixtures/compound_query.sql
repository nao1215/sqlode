-- name: GetAllItems :many
SELECT id, name, price FROM products
UNION ALL
SELECT id, name, price FROM services;

-- name: GetUniqueNames :many
SELECT name FROM products
UNION
SELECT name FROM services;

-- name: GetProductOnly :many
SELECT id, name FROM products
INTERSECT
SELECT id, name FROM services;

-- name: GetExclusiveProducts :many
SELECT id, name FROM products
EXCEPT
SELECT id, name FROM services;
