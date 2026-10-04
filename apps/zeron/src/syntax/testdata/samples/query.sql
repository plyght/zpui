-- comment
CREATE TABLE users (
  id INTEGER PRIMARY KEY,
  name VARCHAR(255) NOT NULL DEFAULT 'anon',
  created_at TIMESTAMP
);
/* block */
SELECT u.name, COUNT(*) AS n
FROM users AS u
LEFT JOIN orders o ON o.user_id = u.id
WHERE u.id > 10 AND u.name LIKE 'a%' OR u.flag IS NULL
GROUP BY u.name HAVING COUNT(*) > 1
ORDER BY n DESC LIMIT 5;
INSERT INTO users (name) VALUES ('b'), (TRUE);
