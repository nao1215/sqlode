CREATE TABLE authors (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  bio TEXT
);

CREATE VIEW active_authors AS
SELECT id, name FROM authors;

CREATE VIEW full_authors AS
SELECT * FROM authors;
