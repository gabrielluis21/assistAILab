-- P08-B Equipment Acquisition: explicit source, canonical actors and concurrency safety.

ALTER TABLE `equipment_acquisitions`
  DROP FOREIGN KEY `equipment_acquisitions_serviceOrderId_fkey`;

ALTER TABLE `equipment_acquisitions`
  MODIFY `consentMethod`
    ENUM('CUSTOMER_APP', 'QR_CODE', 'DIGITAL_SIGNATURE', 'SIGNED_DOCUMENT', 'IN_PERSON_ASSISTED') NULL,
  ADD COLUMN `source` ENUM('SERVICE_ORDER', 'DIRECT_OFFER') NULL,
  ADD COLUMN `clientPreAcquisitionId` VARCHAR(191) NULL,
  ADD COLUMN `createdByUserId` VARCHAR(191) NULL,
  ADD COLUMN `authorizedByUserId` VARCHAR(191) NULL,
  ADD COLUMN `completedByUserId` VARCHAR(191) NULL,
  ADD COLUMN `activeEquipmentGuard` VARCHAR(191) NULL;

-- Historical proof gate: only rows backed by a Service Order are classified.
-- If any legacy row has no Service Order, source remains NULL and the following
-- NOT NULL alteration aborts the migration instead of inventing provenance.
UPDATE `equipment_acquisitions`
SET `source` = 'SERVICE_ORDER'
WHERE `serviceOrderId` IS NOT NULL;

UPDATE `equipment_acquisitions`
SET `activeEquipmentGuard` = `equipmentId`
WHERE `status` IN ('PENDING', 'AUTHORIZED');

ALTER TABLE `equipment_acquisitions`
  MODIFY `source` ENUM('SERVICE_ORDER', 'DIRECT_OFFER') NOT NULL,
  ADD UNIQUE INDEX `equipment_acquisitions_one_active_per_equipment` (`activeEquipmentGuard`),
  ADD UNIQUE INDEX `equipment_acquisitions_organizationId_clientPreAcquisitionId_key`
    (`organizationId`, `clientPreAcquisitionId`),
  ADD INDEX `equipment_acquisitions_source_idx` (`source`),
  ADD INDEX `equipment_acquisitions_createdByUserId_idx` (`createdByUserId`),
  ADD INDEX `equipment_acquisitions_authorizedByUserId_idx` (`authorizedByUserId`),
  ADD INDEX `equipment_acquisitions_completedByUserId_idx` (`completedByUserId`),
  ADD CONSTRAINT `chk_equipment_acquisitions_source_service_order`
    CHECK (
      (`source` = 'SERVICE_ORDER' AND `serviceOrderId` IS NOT NULL)
      OR (`source` = 'DIRECT_OFFER' AND `serviceOrderId` IS NULL)
    ),
  ADD CONSTRAINT `chk_equipment_acquisitions_in_person_source`
    CHECK (
      `consentMethod` IS NULL
      OR `consentMethod` <> 'IN_PERSON_ASSISTED'
      OR `source` = 'DIRECT_OFFER'
    );

ALTER TABLE `equipment_acquisitions`
  ADD CONSTRAINT `equipment_acquisitions_serviceOrderId_fkey`
    FOREIGN KEY (`serviceOrderId`) REFERENCES `service_orders`(`id`)
    ON DELETE RESTRICT ON UPDATE RESTRICT,
  ADD CONSTRAINT `equipment_acquisitions_createdByUserId_fkey`
    FOREIGN KEY (`createdByUserId`) REFERENCES `users`(`id`)
    ON DELETE SET NULL ON UPDATE CASCADE,
  ADD CONSTRAINT `equipment_acquisitions_authorizedByUserId_fkey`
    FOREIGN KEY (`authorizedByUserId`) REFERENCES `users`(`id`)
    ON DELETE SET NULL ON UPDATE CASCADE,
  ADD CONSTRAINT `equipment_acquisitions_completedByUserId_fkey`
    FOREIGN KEY (`completedByUserId`) REFERENCES `users`(`id`)
    ON DELETE SET NULL ON UPDATE CASCADE;

CREATE TRIGGER `equipment_acquisitions_active_guard_insert`
BEFORE INSERT ON `equipment_acquisitions`
FOR EACH ROW
SET NEW.`activeEquipmentGuard` =
  CASE
    WHEN NEW.`status` IN ('PENDING', 'AUTHORIZED') THEN NEW.`equipmentId`
    ELSE NULL
  END;

CREATE TRIGGER `equipment_acquisitions_active_guard_update`
BEFORE UPDATE ON `equipment_acquisitions`
FOR EACH ROW
SET NEW.`activeEquipmentGuard` =
  CASE
    WHEN NEW.`status` IN ('PENDING', 'AUTHORIZED') THEN NEW.`equipmentId`
    ELSE NULL
  END;
