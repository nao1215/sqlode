CREATE TABLE authors (
  id BIGSERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  bio TEXT
);

-- View with an unresolvable column (references a column not present in any
-- base table): under the default (strict_views: false) the column is
-- silently dropped with a stderr warning. Under strict_views: true the
-- generator must fail.
CREATE VIEW broken AS SELECT unknown_column FROM nonexistent_table;
