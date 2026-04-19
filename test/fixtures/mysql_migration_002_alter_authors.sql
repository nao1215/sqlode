ALTER TABLE `authors` ADD COLUMN `is_active` BOOLEAN NOT NULL DEFAULT TRUE;
ALTER TABLE `authors` MODIFY COLUMN `bio` LONGTEXT NULL;
ALTER TABLE `authors` CHANGE COLUMN `full_name` `display_name` VARCHAR(255) NOT NULL;
ALTER TABLE `authors` RENAME COLUMN `display_name` TO `name`;
ALTER TABLE `authors` DROP COLUMN `is_active`;
DROP VIEW `author_names`;
