/*
  Warnings:

  - You are about to drop the `file_metadata` table. If the table is not empty, all the data it contains will be lost.

*/
-- DropTable
DROP TABLE `file_metadata`;

-- CreateTable
CREATE TABLE `customer_profiles` (
    `id` VARCHAR(191) NOT NULL,
    `customerId` VARCHAR(191) NOT NULL,
    `totalServiceOrders` INTEGER NOT NULL DEFAULT 0,
    `completedOrders` INTEGER NOT NULL DEFAULT 0,
    `cancelledOrders` INTEGER NOT NULL DEFAULT 0,
    `notApprovedOrders` INTEGER NOT NULL DEFAULT 0,
    `returnedOrders` INTEGER NOT NULL DEFAULT 0,
    `totalSpent` DECIMAL(12, 2) NOT NULL DEFAULT 0.00,
    `averageTicket` DECIMAL(12, 2) NOT NULL DEFAULT 0.00,
    `averageRating` DECIMAL(3, 2) NULL,
    `feedbackCount` INTEGER NOT NULL DEFAULT 0,
    `firstServiceAt` DATETIME(3) NULL,
    `lastServiceAt` DATETIME(3) NULL,
    `riskLevel` ENUM('LOW', 'MEDIUM', 'HIGH', 'CRITICAL') NOT NULL DEFAULT 'LOW',
    `riskScore` DECIMAL(5, 2) NULL,
    `createdAt` DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updatedAt` DATETIME(3) NOT NULL,

    UNIQUE INDEX `customer_profiles_customerId_key`(`customerId`),
    INDEX `customer_profiles_riskLevel_idx`(`riskLevel`),
    INDEX `customer_profiles_lastServiceAt_idx`(`lastServiceAt`),
    PRIMARY KEY (`id`)
) DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- CreateTable
CREATE TABLE `customer_events` (
    `id` VARCHAR(191) NOT NULL,
    `customerId` VARCHAR(191) NOT NULL,
    `organizationId` VARCHAR(191) NOT NULL,
    `type` ENUM('SERVICE_ORDER_CREATED', 'SERVICE_ORDER_COMPLETED', 'SERVICE_ORDER_CANCELLED', 'SERVICE_ORDER_NOT_APPROVED', 'SERVICE_ORDER_RETURNED', 'PAYMENT_CONFIRMED', 'FEEDBACK_RECEIVED', 'CUSTOMER_REGISTERED', 'CUSTOMER_UPDATED', 'EQUIPMENT_REGISTERED', 'CAMPAIGN_SENT', 'CAMPAIGN_OPENED', 'CAMPAIGN_CLICKED', 'CAMPAIGN_CONVERTED', 'OTHER') NOT NULL,
    `serviceOrderId` VARCHAR(191) NULL,
    `title` VARCHAR(191) NOT NULL,
    `description` TEXT NULL,
    `metadata` JSON NULL,
    `createdAt` DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    INDEX `customer_events_customerId_idx`(`customerId`),
    INDEX `customer_events_organizationId_idx`(`organizationId`),
    INDEX `customer_events_type_idx`(`type`),
    INDEX `customer_events_createdAt_idx`(`createdAt`),
    INDEX `customer_events_customerId_createdAt_idx`(`customerId`, `createdAt`),
    PRIMARY KEY (`id`)
) DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- CreateTable
CREATE TABLE `customer_feedbacks` (
    `id` VARCHAR(191) NOT NULL,
    `customerId` VARCHAR(191) NOT NULL,
    `organizationId` VARCHAR(191) NOT NULL,
    `serviceOrderId` VARCHAR(191) NULL,
    `type` ENUM('SERVICE', 'TECHNICIAN', 'PRODUCT', 'GENERAL') NOT NULL,
    `rating` INTEGER NULL,
    `comment` TEXT NULL,
    `createdAt` DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    INDEX `customer_feedbacks_customerId_idx`(`customerId`),
    INDEX `customer_feedbacks_organizationId_idx`(`organizationId`),
    INDEX `customer_feedbacks_serviceOrderId_idx`(`serviceOrderId`),
    INDEX `customer_feedbacks_type_idx`(`type`),
    INDEX `customer_feedbacks_rating_idx`(`rating`),
    PRIMARY KEY (`id`)
) DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- CreateTable
CREATE TABLE `campaigns` (
    `id` VARCHAR(191) NOT NULL,
    `organizationId` VARCHAR(191) NOT NULL,
    `createdById` VARCHAR(191) NULL,
    `name` VARCHAR(191) NOT NULL,
    `description` TEXT NULL,
    `message` TEXT NOT NULL,
    `audienceType` ENUM('ALL_CUSTOMERS', 'ACTIVE_CUSTOMERS', 'INACTIVE_CUSTOMERS', 'AT_RISK', 'VIP', 'CUSTOM') NOT NULL,
    `status` ENUM('DRAFT', 'SCHEDULED', 'RUNNING', 'PAUSED', 'COMPLETED', 'CANCELLED') NOT NULL DEFAULT 'DRAFT',
    `scheduledAt` DATETIME(3) NULL,
    `startedAt` DATETIME(3) NULL,
    `completedAt` DATETIME(3) NULL,
    `createdAt` DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updatedAt` DATETIME(3) NOT NULL,

    INDEX `campaigns_organizationId_idx`(`organizationId`),
    INDEX `campaigns_organizationId_status_idx`(`organizationId`, `status`),
    INDEX `campaigns_scheduledAt_idx`(`scheduledAt`),
    PRIMARY KEY (`id`)
) DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- CreateTable
CREATE TABLE `campaign_recipients` (
    `id` VARCHAR(191) NOT NULL,
    `campaignId` VARCHAR(191) NOT NULL,
    `customerId` VARCHAR(191) NOT NULL,
    `channel` ENUM('WHATSAPP', 'SMS', 'EMAIL', 'PUSH') NOT NULL,
    `status` ENUM('PENDING', 'SENT', 'DELIVERED', 'OPENED', 'CLICKED', 'CONVERTED', 'FAILED', 'UNSUBSCRIBED') NOT NULL DEFAULT 'PENDING',
    `sentAt` DATETIME(3) NULL,
    `deliveredAt` DATETIME(3) NULL,
    `openedAt` DATETIME(3) NULL,
    `clickedAt` DATETIME(3) NULL,
    `convertedAt` DATETIME(3) NULL,
    `externalMessageId` VARCHAR(191) NULL,
    `createdAt` DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updatedAt` DATETIME(3) NOT NULL,

    INDEX `campaign_recipients_campaignId_idx`(`campaignId`),
    INDEX `campaign_recipients_customerId_idx`(`customerId`),
    INDEX `campaign_recipients_status_idx`(`status`),
    UNIQUE INDEX `campaign_recipients_campaignId_customerId_channel_key`(`campaignId`, `customerId`, `channel`),
    PRIMARY KEY (`id`)
) DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- CreateTable
CREATE TABLE `media_assets` (
    `id` VARCHAR(191) NOT NULL,
    `organizationId` VARCHAR(191) NOT NULL,
    `uploadedById` VARCHAR(191) NULL,
    `entityType` ENUM('CUSTOMER', 'EQUIPMENT', 'SERVICE_ORDER', 'SERVICE_ORDER_ITEM', 'PART', 'AI_ANALYSIS', 'OTHER') NOT NULL,
    `entityId` VARCHAR(191) NOT NULL,
    `purpose` ENUM('EQUIPMENT_PHOTO', 'DEFECT_PHOTO', 'PART_PHOTO', 'BEFORE_SERVICE', 'AFTER_SERVICE', 'DOCUMENT', 'AI_REFERENCE', 'OTHER') NOT NULL,
    `filename` VARCHAR(191) NOT NULL,
    `mimeType` VARCHAR(191) NOT NULL,
    `sizeBytes` BIGINT NOT NULL,
    `hashSha256` VARCHAR(191) NOT NULL,
    `storageKey` VARCHAR(191) NOT NULL,
    `publicUrl` VARCHAR(191) NULL,
    `createdAt` DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updatedAt` DATETIME(3) NOT NULL,
    `customerId` VARCHAR(191) NULL,
    `equipmentId` VARCHAR(191) NULL,
    `serviceOrderId` VARCHAR(191) NULL,
    `serviceOrderItemId` VARCHAR(191) NULL,
    `partId` VARCHAR(191) NULL,

    INDEX `media_assets_organizationId_idx`(`organizationId`),
    INDEX `media_assets_entityType_entityId_idx`(`entityType`, `entityId`),
    INDEX `media_assets_purpose_idx`(`purpose`),
    INDEX `media_assets_customerId_idx`(`customerId`),
    INDEX `media_assets_equipmentId_idx`(`equipmentId`),
    INDEX `media_assets_serviceOrderId_idx`(`serviceOrderId`),
    INDEX `media_assets_serviceOrderItemId_idx`(`serviceOrderItemId`),
    INDEX `media_assets_partId_idx`(`partId`),
    INDEX `media_assets_hashSha256_idx`(`hashSha256`),
    PRIMARY KEY (`id`)
) DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- CreateTable
CREATE TABLE `ai_analyses` (
    `id` VARCHAR(191) NOT NULL,
    `organizationId` VARCHAR(191) NOT NULL,
    `mediaAssetId` VARCHAR(191) NOT NULL,
    `provider` VARCHAR(191) NOT NULL,
    `model` VARCHAR(191) NULL,
    `status` ENUM('PENDING', 'PROCESSING', 'COMPLETED', 'FAILED') NOT NULL DEFAULT 'PENDING',
    `promptVersion` VARCHAR(191) NULL,
    `requestData` JSON NULL,
    `responseData` JSON NULL,
    `detectedType` VARCHAR(191) NULL,
    `detectedBrand` VARCHAR(191) NULL,
    `detectedModel` VARCHAR(191) NULL,
    `detectedPart` VARCHAR(191) NULL,
    `diagnosis` TEXT NULL,
    `confidence` DECIMAL(5, 2) NULL,
    `errorMessage` TEXT NULL,
    `createdAt` DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `startedAt` DATETIME(3) NULL,
    `completedAt` DATETIME(3) NULL,

    INDEX `ai_analyses_organizationId_idx`(`organizationId`),
    INDEX `ai_analyses_mediaAssetId_idx`(`mediaAssetId`),
    INDEX `ai_analyses_status_idx`(`status`),
    PRIMARY KEY (`id`)
) DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- AddForeignKey
ALTER TABLE `customer_profiles` ADD CONSTRAINT `customer_profiles_customerId_fkey` FOREIGN KEY (`customerId`) REFERENCES `customers`(`id`) ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `customer_events` ADD CONSTRAINT `customer_events_customerId_fkey` FOREIGN KEY (`customerId`) REFERENCES `customers`(`id`) ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `customer_events` ADD CONSTRAINT `customer_events_organizationId_fkey` FOREIGN KEY (`organizationId`) REFERENCES `organizations`(`id`) ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `customer_events` ADD CONSTRAINT `customer_events_serviceOrderId_fkey` FOREIGN KEY (`serviceOrderId`) REFERENCES `service_orders`(`id`) ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `customer_feedbacks` ADD CONSTRAINT `customer_feedbacks_customerId_fkey` FOREIGN KEY (`customerId`) REFERENCES `customers`(`id`) ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `customer_feedbacks` ADD CONSTRAINT `customer_feedbacks_serviceOrderId_fkey` FOREIGN KEY (`serviceOrderId`) REFERENCES `service_orders`(`id`) ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `campaigns` ADD CONSTRAINT `campaigns_organizationId_fkey` FOREIGN KEY (`organizationId`) REFERENCES `organizations`(`id`) ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `campaigns` ADD CONSTRAINT `campaigns_createdById_fkey` FOREIGN KEY (`createdById`) REFERENCES `users`(`id`) ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `campaign_recipients` ADD CONSTRAINT `campaign_recipients_campaignId_fkey` FOREIGN KEY (`campaignId`) REFERENCES `campaigns`(`id`) ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `media_assets` ADD CONSTRAINT `media_assets_organizationId_fkey` FOREIGN KEY (`organizationId`) REFERENCES `organizations`(`id`) ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `media_assets` ADD CONSTRAINT `media_assets_uploadedById_fkey` FOREIGN KEY (`uploadedById`) REFERENCES `users`(`id`) ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `media_assets` ADD CONSTRAINT `media_assets_customerId_fkey` FOREIGN KEY (`customerId`) REFERENCES `customers`(`id`) ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `media_assets` ADD CONSTRAINT `media_assets_equipmentId_fkey` FOREIGN KEY (`equipmentId`) REFERENCES `equipments`(`id`) ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `media_assets` ADD CONSTRAINT `media_assets_serviceOrderId_fkey` FOREIGN KEY (`serviceOrderId`) REFERENCES `service_orders`(`id`) ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `media_assets` ADD CONSTRAINT `media_assets_serviceOrderItemId_fkey` FOREIGN KEY (`serviceOrderItemId`) REFERENCES `service_order_items`(`id`) ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `media_assets` ADD CONSTRAINT `media_assets_partId_fkey` FOREIGN KEY (`partId`) REFERENCES `parts`(`id`) ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `ai_analyses` ADD CONSTRAINT `ai_analyses_organizationId_fkey` FOREIGN KEY (`organizationId`) REFERENCES `organizations`(`id`) ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `ai_analyses` ADD CONSTRAINT `ai_analyses_mediaAssetId_fkey` FOREIGN KEY (`mediaAssetId`) REFERENCES `media_assets`(`id`) ON DELETE CASCADE ON UPDATE CASCADE;
