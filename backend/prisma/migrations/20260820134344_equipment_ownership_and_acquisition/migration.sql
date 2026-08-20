-- DropForeignKey
ALTER TABLE `equipments` DROP FOREIGN KEY `equipments_customerId_fkey`;

-- AlterTable
ALTER TABLE `equipments` ADD COLUMN `organizationId` VARCHAR(191) NULL,
    ADD COLUMN `organizationPurpose` ENUM('RESALE', 'PARTS_DONOR', 'INTERNAL_USE') NULL,
    ADD COLUMN `ownerType` ENUM('CUSTOMER', 'ORGANIZATION') NOT NULL DEFAULT 'CUSTOMER',
    MODIFY `customerId` VARCHAR(191) NULL;

-- CreateTable
CREATE TABLE `equipment_acquisitions` (
    `id` VARCHAR(191) NOT NULL,
    `equipmentId` VARCHAR(191) NOT NULL,
    `customerId` VARCHAR(191) NOT NULL,
    `organizationId` VARCHAR(191) NOT NULL,
    `serviceOrderId` VARCHAR(191) NULL,
    `purpose` ENUM('RESALE', 'PARTS_DONOR', 'INTERNAL_USE') NOT NULL,
    `status` ENUM('PENDING', 'AUTHORIZED', 'REJECTED', 'CANCELLED', 'COMPLETED') NOT NULL DEFAULT 'PENDING',
    `offeredAmount` DECIMAL(10, 2) NULL,
    `consentMethod` ENUM('CUSTOMER_APP', 'QR_CODE', 'DIGITAL_SIGNATURE', 'SIGNED_DOCUMENT') NULL,
    `consentSnapshot` JSON NULL,
    `consentHash` VARCHAR(191) NULL,
    `authorizedAt` DATETIME(3) NULL,
    `rejectedAt` DATETIME(3) NULL,
    `cancelledAt` DATETIME(3) NULL,
    `completedAt` DATETIME(3) NULL,
    `notes` TEXT NULL,
    `createdAt` DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updatedAt` DATETIME(3) NOT NULL,

    INDEX `equipment_acquisitions_equipmentId_idx`(`equipmentId`),
    INDEX `equipment_acquisitions_customerId_idx`(`customerId`),
    INDEX `equipment_acquisitions_organizationId_idx`(`organizationId`),
    INDEX `equipment_acquisitions_serviceOrderId_idx`(`serviceOrderId`),
    INDEX `equipment_acquisitions_status_idx`(`status`),
    INDEX `equipment_acquisitions_purpose_idx`(`purpose`),
    INDEX `equipment_acquisitions_organizationId_status_idx`(`organizationId`, `status`),
    PRIMARY KEY (`id`)
) DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- CreateIndex
CREATE INDEX `equipments_organizationId_idx` ON `equipments`(`organizationId`);

-- CreateIndex
CREATE INDEX `equipments_ownerType_idx` ON `equipments`(`ownerType`);

-- CreateIndex
CREATE INDEX `equipments_organizationPurpose_idx` ON `equipments`(`organizationPurpose`);

-- AddForeignKey
ALTER TABLE `equipments` ADD CONSTRAINT `equipments_customerId_fkey` FOREIGN KEY (`customerId`) REFERENCES `customers`(`id`) ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `equipments` ADD CONSTRAINT `equipments_organizationId_fkey` FOREIGN KEY (`organizationId`) REFERENCES `organizations`(`id`) ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `equipment_acquisitions` ADD CONSTRAINT `equipment_acquisitions_equipmentId_fkey` FOREIGN KEY (`equipmentId`) REFERENCES `equipments`(`id`) ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `equipment_acquisitions` ADD CONSTRAINT `equipment_acquisitions_customerId_fkey` FOREIGN KEY (`customerId`) REFERENCES `customers`(`id`) ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `equipment_acquisitions` ADD CONSTRAINT `equipment_acquisitions_organizationId_fkey` FOREIGN KEY (`organizationId`) REFERENCES `organizations`(`id`) ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `equipment_acquisitions` ADD CONSTRAINT `equipment_acquisitions_serviceOrderId_fkey` FOREIGN KEY (`serviceOrderId`) REFERENCES `service_orders`(`id`) ON DELETE SET NULL ON UPDATE CASCADE;
