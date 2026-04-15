CREATE TABLE articles (
  id BIGSERIAL PRIMARY KEY,
  title TEXT NOT NULL,
  tags TEXT[],
  scores INTEGER[]
);
