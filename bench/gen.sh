#!/bin/sh
# Writes the inputs of the himorime suite in bench/. Both revisions of a
# comparison run the working tree's copy (${head_root}/gen.sh), so they read
# the same bytes.
#
#   sh gen.sh project N DIR   a SQLite project in DIR: DIR/db/schema.sql with
#                             one table per ten queries (at least one),
#                             DIR/db/query.sql with N queries and
#                             DIR/sqlode.yaml, which generates into
#                             DIR/src/db. Deterministic: the same N always
#                             writes the same bytes.
#
# The queries cycle through :one, :many with a JOIN, and :exec, over tables
# that each have an integer key, text columns, a nullable column and a
# default, so the parser, the analyser and every generated module get work
# to do. SQLite needs no server, so the suite does not go to the network.
set -eu

case "$1" in
project)
	n="$2"
	dir="$3"
	if [ "$n" -lt 1 ]; then
		echo "gen.sh: the number of queries must be at least 1, got $n" >&2
		exit 2
	fi
	mkdir -p "$dir/db"
	awk -v queries="$n" -v schema="$dir/db/schema.sql" -v query="$dir/db/query.sql" 'BEGIN {
		tables = int((queries + 9) / 10)
		for (t = 1; t <= tables; t++) {
			print "CREATE TABLE authors" t " (" > schema
			print "  id INTEGER PRIMARY KEY," > schema
			print "  name TEXT NOT NULL," > schema
			print "  bio TEXT," > schema
			print "  age INTEGER NOT NULL," > schema
			print "  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP" > schema
			print ");" > schema
			print "" > schema
			print "CREATE TABLE books" t " (" > schema
			print "  id INTEGER PRIMARY KEY," > schema
			print "  author_id INTEGER NOT NULL REFERENCES authors" t "(id)," > schema
			print "  title TEXT NOT NULL" > schema
			print ");" > schema
			print "" > schema
		}
		for (q = 1; q <= queries; q++) {
			t = int((q - 1) / 10) + 1
			k = q % 3
			if (k == 1) {
				print "-- name: GetAuthor" q " :one" > query
				print "SELECT id, name, bio, age FROM authors" t " WHERE id = ? AND age > ?;" > query
			} else if (k == 2) {
				print "-- name: ListBooks" q " :many" > query
				print "SELECT b.id, b.title, a.name FROM books" t " b JOIN authors" t " a ON a.id = b.author_id WHERE a.age > ? ORDER BY b.title;" > query
			} else {
				print "-- name: CreateAuthor" q " :exec" > query
				print "INSERT INTO authors" t " (name, bio, age) VALUES (?, ?, ?);" > query
			}
			print "" > query
		}
	}'
	cat > "$dir/sqlode.yaml" <<'EOF'
version: "2"
sql:
  - schema: "db/schema.sql"
    queries: "db/query.sql"
    engine: "sqlite"
    gen:
      gleam:
        out: "src/db"
        runtime: "raw"
EOF
	;;
*)
	echo "gen.sh: unknown kind $1" >&2
	exit 2
	;;
esac
