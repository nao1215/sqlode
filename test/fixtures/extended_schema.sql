CREATE TABLE events (
  id BIGSERIAL PRIMARY KEY,
  title TEXT NOT NULL,
  description TEXT,
  event_date DATE NOT NULL,
  start_time TIME NOT NULL,
  created_at TIMESTAMP NOT NULL,
  metadata JSONB,
  external_id UUID NOT NULL
);
