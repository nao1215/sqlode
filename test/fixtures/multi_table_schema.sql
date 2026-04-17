CREATE TYPE used_status AS ENUM ('active', 'inactive');
CREATE TYPE unused_status AS ENUM ('draft', 'published');

CREATE TABLE authors (
  id BIGSERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  status used_status NOT NULL
);

CREATE TABLE unused_table (
  id BIGSERIAL PRIMARY KEY,
  label TEXT NOT NULL,
  state unused_status NOT NULL
);
