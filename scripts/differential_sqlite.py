#!/usr/bin/env python3
"""Differential test of sqlode's SQLite analysis against SQLite itself.

For each SQLite schema and query file below, sqlode's analysis (printed by
test/sqlite_oracle_dump.gleam) is compared with what SQLite reports when it
prepares the SQL the generated code sends:

- the number of values the generated code binds must be the number of
  parameters SQLite expects, and
- for statements that return rows, the result columns must have the same
  names in the same order, since the generated decoders read them by
  position.

SQLite comes from Python's standard sqlite3 module. Each statement runs on
an empty in-memory database inside a savepoint that is rolled back, with
NULL for every parameter, so constraint errors are expected and ignored:
they come after SQLite has bound the parameters and named the columns.

Usage: python3 scripts/differential_sqlite.py  (from the repository root,
with gleam on PATH)
"""
import re
import sqlite3
import subprocess
import sys

CASES = [
    ("test/fixtures/sqlite_schema.sql", "test/fixtures/sqlite_query.sql"),
    ("test/fixtures/sqlite_schema.sql", "test/fixtures/sqlite_crud_query.sql"),
    ("test/fixtures/all_commands_schema.sql", "test/fixtures/all_commands_query.sql"),
    ("test/fixtures/sqlite_advanced_schema.sql", "test/fixtures/sqlite_advanced_query.sql"),
    ("test/fixtures/sqlite_extended_schema.sql", "test/fixtures/sqlite_extended_query.sql"),
    ("test/fixtures/sqlite_advanced_schema.sql", "test/fixtures/sqlite_differential_query.sql"),
]

BINDINGS = re.compile(r"current statement uses (\d+)")
# Named parameters (:name, @name, $name) outside string literals and quoted
# identifiers. SQLite gives every distinct name one parameter slot.
TOKENS = re.compile(r"'(?:[^']|'')*'|\"(?:[^\"]|\"\")*\"|`[^`]*`|[:@$][A-Za-z_][A-Za-z0-9_]*")


def named_parameters(sql):
    names = []
    for token in TOKENS.findall(sql):
        if token[0] in ":@$" and token not in names:
            names.append(token)
    return names


def sqlode_view(schema, queries):
    out = subprocess.run(
        ["gleam", "run", "--no-print-progress", "-m", "sqlite_oracle_dump", "--", schema, queries],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    rows = []
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) == 4 and parts[0] == "rejected":
            rows.append((parts[1], None, None, parts[3], parts[2]))
            continue
        if len(parts) != 5:
            continue
        name, returns_rows, count, columns, sql = parts
        rows.append((name, returns_rows == "true", int(count), [c for c in columns.split(",") if c], sql))
    return rows


def run_once(con, sql, count, value):
    """Run sql with every parameter set to value inside a rolled back
    savepoint. Return (parameters SQLite expects, result column names)."""
    con.execute("SAVEPOINT probe")
    try:
        cur = con.cursor()
        named = named_parameters(sql)
        try:
            if named:
                # The generated code binds by position; SQLite numbers the
                # distinct names in order of first appearance.
                cur.execute(sql, {n[1:]: value for n in named})
                expected = len(named)
            else:
                cur.execute(sql, [value] * count)
                expected = count
        except sqlite3.ProgrammingError as error:
            match = BINDINGS.search(str(error))
            if not match:
                raise
            return int(match.group(1)), None
        names = [d[0] for d in cur.description] if cur.description else None
        # A RETURNING statement stays in progress until its rows are read,
        # and an open statement blocks the rollback below.
        cur.fetchall()
        cur.close()
        return expected, names
    finally:
        con.execute("ROLLBACK TO probe")
        con.execute("RELEASE probe")


def sqlite_view(con, sql, count):
    """Return (parameters SQLite expects, result column names or None).

    NULL is tried first. A NOT NULL constraint or `LIMIT NULL` rejects it
    after the parameters were bound, so 0 is tried next to get to the
    result columns."""
    for value in (None, 0):
        try:
            return run_once(con, sql, count, value)
        except sqlite3.IntegrityError:
            continue
    return count, None


def main():
    failures = []
    checked = 0
    for schema, queries in CASES:
        con = sqlite3.connect(":memory:")
        con.isolation_level = None
        with open(schema, encoding="utf-8") as f:
            con.executescript(f.read())
        for name, returns_rows, count, columns, sql in sqlode_view(schema, queries):
            checked += 1
            if returns_rows is None:
                failures.append(f"{queries} {name}: sqlode rejects a query SQLite accepts: {columns}\n  {sql}")
                continue
            try:
                params, names = sqlite_view(con, sql, count)
            except sqlite3.Error as error:
                failures.append(f"{queries} {name}: SQLite rejects the generated SQL: {error}\n  {sql}")
                continue
            if params != count:
                failures.append(f"{queries} {name}: sqlode binds {count} values, SQLite expects {params}\n  {sql}")
            if returns_rows and names != columns:
                failures.append(f"{queries} {name}: sqlode reads columns {columns}, SQLite returns {names}\n  {sql}")
        con.close()
    print(f"compared {checked} queries with SQLite {sqlite3.sqlite_version}")
    for failure in failures:
        print("MISMATCH " + failure)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
