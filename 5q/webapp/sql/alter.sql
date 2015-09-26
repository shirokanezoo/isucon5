ALTER TABLE `entries` ADD COLUMN `title` TEXT AFTER `private`;
UPDATE entries SET title =  SUBSTRING_INDEX(body, "\n", 1), body = SUBSTRING(body FROM LOCATE("\n", body) + 1) WHERE title IS NULL;
ALTER TABLE relations ADD INDEX friendship_a (`one`,`created_at`);
ALTER TABLE relations ADD INDEX friendship_b (`another`,`created_at`);
