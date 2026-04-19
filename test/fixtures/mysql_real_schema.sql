CREATE TABLE authors (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  email VARCHAR(255) NOT NULL UNIQUE,
  display_name VARCHAR(255) NOT NULL,
  bio TEXT NULL,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  avatar BLOB NULL,
  balance DECIMAL(20,6) NOT NULL DEFAULT '0.000000',
  status ENUM('draft','published','archived') NOT NULL DEFAULT 'draft',
  tags SET('red','green','blue') NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
