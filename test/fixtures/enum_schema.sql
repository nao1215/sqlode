CREATE TYPE status AS ENUM ('active', 'inactive', 'banned');

CREATE TABLE users (
  id SERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  status status NOT NULL
);
