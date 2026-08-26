-- SEC-F01 — OperationIdempotency v2
-- MySQL / Prisma 5.x
--
-- Legacy records are deterministically treated as COMPLETED because the
-- pre-SEC-F01 schema could only persist responseStatus/responseBody as NOT NULL.
-- New v2 reservations explicitly insert status='PROCESSING'.

ALTER TABLE `operation_idempotency`
  ADD COLUMN `organizationId` VARCHAR(191) NULL,
  ADD COLUMN `command` VARCHAR(191) NULL,
  ADD COLUMN `status` ENUM('PROCESSING', 'COMPLETED') NOT NULL DEFAULT 'COMPLETED',
  ADD COLUMN `processingExpiresAt` DATETIME(3) NULL,
  ADD COLUMN `completedAt` DATETIME(3) NULL,
  ADD COLUMN `updatedAt` DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3);

UPDATE `operation_idempotency`
SET
  `status` = 'COMPLETED',
  `completedAt` = `createdAt`
WHERE `completedAt` IS NULL;

ALTER TABLE `operation_idempotency`
  MODIFY `responseStatus` INTEGER NULL,
  MODIFY `responseBody` JSON NULL;

CREATE INDEX `operation_idempotency_status_processingExpiresAt_idx`
  ON `operation_idempotency`(`status`, `processingExpiresAt`);

CREATE INDEX `operation_idempotency_organizationId_idx`
  ON `operation_idempotency`(`organizationId`);

CREATE INDEX `operation_idempotency_command_idx`
  ON `operation_idempotency`(`command`);
