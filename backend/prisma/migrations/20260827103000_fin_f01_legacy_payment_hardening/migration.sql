-- FIN-F01 — Legacy Payment Tenant + Security Hardening
-- MySQL / Prisma 5.x
--
-- WRITE FREEZE:
-- `payments` is atomically renamed away from the application-visible table
-- name while backfill + DDL run. Existing REST/Sync writers therefore cannot
-- write Payment during the migration. Preflight MUST be run before deploy.

RENAME TABLE `payments` TO `payments_fin_f01_write_frozen`;

ALTER TABLE `payments_fin_f01_write_frozen`
  ADD COLUMN `organizationId` VARCHAR(191) NULL,
  ADD COLUMN `clientOperationId` VARCHAR(191) NULL,
  ADD COLUMN `createdByUserId` VARCHAR(191) NULL,
  ADD COLUMN `confirmedByUserId` VARCHAR(191) NULL,
  ADD COLUMN `cancelledByUserId` VARCHAR(191) NULL,
  ADD COLUMN `cancelledAt` DATETIME(3) NULL,
  ADD COLUMN `version` INTEGER NOT NULL DEFAULT 1;

-- ServiceOrder is authoritative for BOTH tenant and customer.
UPDATE `payments_fin_f01_write_frozen` AS p
INNER JOIN `service_orders` AS so
  ON so.`id` = p.`serviceOrderId`
SET
  p.`organizationId` = so.`organizationId`,
  p.`customerId` = so.`customerId`,
  p.`clientOperationId` = CONCAT('legacy:', p.`id`);

-- If any Payment is orphaned, organizationId remains NULL and this ALTER
-- fails rather than silently fabricating tenant authority.
ALTER TABLE `payments_fin_f01_write_frozen`
  MODIFY `organizationId` VARCHAR(191) NOT NULL,
  MODIFY `clientOperationId` VARCHAR(191) NOT NULL,
  MODIFY `amount` DECIMAL(14, 2) NOT NULL;

CREATE UNIQUE INDEX `payments_clientOperationId_key`
  ON `payments_fin_f01_write_frozen`(`clientOperationId`);

CREATE INDEX `payments_organizationId_idx`
  ON `payments_fin_f01_write_frozen`(`organizationId`);

CREATE INDEX `payments_organizationId_status_idx`
  ON `payments_fin_f01_write_frozen`(`organizationId`, `status`);

CREATE INDEX `payments_organizationId_createdAt_idx`
  ON `payments_fin_f01_write_frozen`(`organizationId`, `createdAt`);

CREATE INDEX `payments_createdByUserId_idx`
  ON `payments_fin_f01_write_frozen`(`createdByUserId`);

CREATE INDEX `payments_confirmedByUserId_idx`
  ON `payments_fin_f01_write_frozen`(`confirmedByUserId`);

CREATE INDEX `payments_cancelledByUserId_idx`
  ON `payments_fin_f01_write_frozen`(`cancelledByUserId`);

CREATE INDEX `payments_cancelledAt_idx`
  ON `payments_fin_f01_write_frozen`(`cancelledAt`);

ALTER TABLE `payments_fin_f01_write_frozen`
  ADD CONSTRAINT `payments_organizationId_fkey`
    FOREIGN KEY (`organizationId`)
    REFERENCES `organizations`(`id`)
    ON DELETE RESTRICT
    ON UPDATE CASCADE,
  ADD CONSTRAINT `payments_createdByUserId_fkey`
    FOREIGN KEY (`createdByUserId`)
    REFERENCES `users`(`id`)
    ON DELETE RESTRICT
    ON UPDATE CASCADE,
  ADD CONSTRAINT `payments_confirmedByUserId_fkey`
    FOREIGN KEY (`confirmedByUserId`)
    REFERENCES `users`(`id`)
    ON DELETE RESTRICT
    ON UPDATE CASCADE,
  ADD CONSTRAINT `payments_cancelledByUserId_fkey`
    FOREIGN KEY (`cancelledByUserId`)
    REFERENCES `users`(`id`)
    ON DELETE RESTRICT
    ON UPDATE CASCADE;

RENAME TABLE `payments_fin_f01_write_frozen` TO `payments`;
