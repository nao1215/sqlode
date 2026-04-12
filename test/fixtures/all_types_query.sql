-- name: GetAllTypes :one
SELECT * FROM all_types WHERE id = $1;

-- name: ListAllTypes :many
SELECT * FROM all_types ORDER BY id;

-- name: InsertAllTypes :exec
INSERT INTO all_types (
  col_int, col_smallint, col_bigint, col_serial,
  col_float, col_double, col_real, col_numeric, col_decimal,
  col_bool, col_text, col_varchar, col_char,
  col_bytea, col_timestamp, col_datetime, col_date, col_time, col_timetz,
  col_uuid, col_json, col_jsonb
) VALUES (
  $1, $2, $3, $4, $5, $6, $7, $8, $9, $10,
  $11, $12, $13, $14, $15, $16, $17, $18, $19, $20, $21
);
