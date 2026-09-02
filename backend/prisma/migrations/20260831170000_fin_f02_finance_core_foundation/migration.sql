-- ============================================================
-- AssistAiLab â€” FIN-F02 Finance Core Foundation
-- Rebuilt deterministically from frozen baseline schema.
--
-- NO synthetic financial history.
-- Legacy ServiceOrders remain financeCoreVersion NULL.
-- ============================================================
-- AlterTable
ALTER TABLE `organizations` ADD COLUMN `timezone` VARCHAR(64) NOT NULL DEFAULT 'America/Sao_Paulo';

-- AlterTable
ALTER TABLE `service_orders` ADD COLUMN `currentQuoteRevisionId` VARCHAR(191) NULL,
    ADD COLUMN `financeCoreVersion` INTEGER NULL,
    ADD COLUMN `lastApprovedQuoteRevisionId` VARCHAR(191) NULL,
    MODIFY `status` ENUM('DRAFT', 'DIAGNOSTICO', 'AGUARDANDO_APROVACAO', 'AGUARDANDO_REAPROVACAO', 'EM_EXECUCAO', 'PRONTO', 'ENTREGUE', 'CANCELADO') NOT NULL DEFAULT 'DIAGNOSTICO';

-- AlterTable
ALTER TABLE `service_order_status_history` MODIFY `previousStatus` ENUM('DRAFT', 'DIAGNOSTICO', 'AGUARDANDO_APROVACAO', 'AGUARDANDO_REAPROVACAO', 'EM_EXECUCAO', 'PRONTO', 'ENTREGUE', 'CANCELADO') NULL,
    MODIFY `newStatus` ENUM('DRAFT', 'DIAGNOSTICO', 'AGUARDANDO_APROVACAO', 'AGUARDANDO_REAPROVACAO', 'EM_EXECUCAO', 'PRONTO', 'ENTREGUE', 'CANCELADO') NOT NULL;

-- AlterTable
ALTER TABLE `payments` ADD COLUMN `cardInstallmentCount` INTEGER NULL;

-- CreateTable
CREATE TABLE `service_order_quote_revisions` (
    `id` VARCHAR(191) NOT NULL,
    `serviceOrderId` VARCHAR(191) NOT NULL,
    `organizationId` VARCHAR(191) NOT NULL,
    `customerId` VARCHAR(191) NOT NULL,
    `revisionNumber` INTEGER NOT NULL,
    `diagnosisSnapshot` TEXT NULL,
    `serviceItemsSnapshot` JSON NOT NULL,
    `partsSnapshot` JSON NOT NULL,
    `totalAmount` DECIMAL(14, 2) NOT NULL,
    `changeType` ENUM('INITIAL', 'COMMERCIAL_CHANGE') NOT NULL,
    `changeReason` TEXT NULL,
    `quoteSnapshot` JSON NOT NULL,
    `quoteHash` CHAR(64) NOT NULL,
    `createdByUserId` VARCHAR(191) NOT NULL,
    `createdAt` DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    INDEX `service_order_quote_revisions_organizationId_idx`(`organizationId`),
    INDEX `service_order_quote_revisions_customerId_idx`(`customerId`),
    INDEX `service_order_quote_revisions_serviceOrderId_createdAt_idx`(`serviceOrderId`, `createdAt`),
    INDEX `service_order_quote_revisions_quoteHash_idx`(`quoteHash`),
    UNIQUE INDEX `service_order_quote_revisions_serviceOrderId_revisionNumber_key`(`serviceOrderId`, `revisionNumber`),
    PRIMARY KEY (`id`)
) DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- CreateTable
CREATE TABLE `customer_quote_decisions` (
    `id` VARCHAR(191) NOT NULL,
    `quoteRevisionId` VARCHAR(191) NOT NULL,
    `serviceOrderId` VARCHAR(191) NOT NULL,
    `organizationId` VARCHAR(191) NOT NULL,
    `customerId` VARCHAR(191) NOT NULL,
    `decision` ENUM('APPROVE', 'REJECT') NOT NULL,
    `reason` TEXT NULL,
    `decidedByUserId` VARCHAR(191) NOT NULL,
    `decidedAt` DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    UNIQUE INDEX `customer_quote_decisions_quoteRevisionId_key`(`quoteRevisionId`),
    INDEX `customer_quote_decisions_serviceOrderId_idx`(`serviceOrderId`),
    INDEX `customer_quote_decisions_organizationId_idx`(`organizationId`),
    INDEX `customer_quote_decisions_customerId_idx`(`customerId`),
    INDEX `customer_quote_decisions_decidedAt_idx`(`decidedAt`),
    PRIMARY KEY (`id`)
) DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- CreateTable
CREATE TABLE `receivables` (
    `id` VARCHAR(191) NOT NULL,
    `organizationId` VARCHAR(191) NOT NULL,
    `customerId` VARCHAR(191) NOT NULL,
    `serviceOrderId` VARCHAR(191) NOT NULL,
    `sourceQuoteRevisionId` VARCHAR(191) NOT NULL,
    `totalAmount` DECIMAL(14, 2) NOT NULL,
    `lifecycleStatus` ENUM('ACTIVE', 'CANCELLED') NOT NULL DEFAULT 'ACTIVE',
    `currentScheduleVersion` INTEGER NOT NULL DEFAULT 1,
    `version` INTEGER NOT NULL DEFAULT 1,
    `issuedAt` DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `createdByUserId` VARCHAR(191) NOT NULL,
    `cancelledAt` DATETIME(3) NULL,
    `cancelledByUserId` VARCHAR(191) NULL,
    `cancellationReason` TEXT NULL,
    `createdAt` DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updatedAt` DATETIME(3) NOT NULL,

    UNIQUE INDEX `receivables_sourceQuoteRevisionId_key`(`sourceQuoteRevisionId`),
    INDEX `receivables_organizationId_idx`(`organizationId`),
    INDEX `receivables_organizationId_lifecycleStatus_idx`(`organizationId`, `lifecycleStatus`),
    INDEX `receivables_customerId_idx`(`customerId`),
    INDEX `receivables_serviceOrderId_idx`(`serviceOrderId`),
    INDEX `receivables_issuedAt_idx`(`issuedAt`),
    PRIMARY KEY (`id`)
) DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- CreateTable
CREATE TABLE `receivable_schedules` (
    `id` VARCHAR(191) NOT NULL,
    `organizationId` VARCHAR(191) NOT NULL,
    `receivableId` VARCHAR(191) NOT NULL,
    `version` INTEGER NOT NULL,
    `createdByUserId` VARCHAR(191) NOT NULL,
    `createdAt` DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    INDEX `receivable_schedules_organizationId_idx`(`organizationId`),
    INDEX `receivable_schedules_createdAt_idx`(`createdAt`),
    UNIQUE INDEX `receivable_schedules_receivableId_version_key`(`receivableId`, `version`),
    PRIMARY KEY (`id`)
) DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- CreateTable
CREATE TABLE `receivable_installments` (
    `id` VARCHAR(191) NOT NULL,
    `organizationId` VARCHAR(191) NOT NULL,
    `receivableId` VARCHAR(191) NOT NULL,
    `scheduleId` VARCHAR(191) NOT NULL,
    `scheduleVersion` INTEGER NOT NULL,
    `sequence` INTEGER NOT NULL,
    `amount` DECIMAL(14, 2) NOT NULL,
    `dueDate` DATE NOT NULL,
    `createdAt` DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    INDEX `receivable_installments_organizationId_idx`(`organizationId`),
    INDEX `receivable_installments_receivableId_idx`(`receivableId`),
    INDEX `receivable_installments_receivableId_scheduleVersion_idx`(`receivableId`, `scheduleVersion`),
    INDEX `receivable_installments_dueDate_idx`(`dueDate`),
    UNIQUE INDEX `receivable_installments_scheduleId_sequence_key`(`scheduleId`, `sequence`),
    PRIMARY KEY (`id`)
) DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- CreateTable
CREATE TABLE `payment_allocations` (
    `id` VARCHAR(191) NOT NULL,
    `organizationId` VARCHAR(191) NOT NULL,
    `customerId` VARCHAR(191) NOT NULL,
    `serviceOrderId` VARCHAR(191) NOT NULL,
    `receivableId` VARCHAR(191) NOT NULL,
    `installmentId` VARCHAR(191) NOT NULL,
    `paymentId` VARCHAR(191) NOT NULL,
    `amount` DECIMAL(14, 2) NOT NULL,
    `createdByUserId` VARCHAR(191) NOT NULL,
    `createdAt` DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    INDEX `payment_allocations_organizationId_idx`(`organizationId`),
    INDEX `payment_allocations_customerId_idx`(`customerId`),
    INDEX `payment_allocations_serviceOrderId_idx`(`serviceOrderId`),
    INDEX `payment_allocations_receivableId_idx`(`receivableId`),
    INDEX `payment_allocations_installmentId_idx`(`installmentId`),
    INDEX `payment_allocations_paymentId_idx`(`paymentId`),
    INDEX `payment_allocations_createdAt_idx`(`createdAt`),
    PRIMARY KEY (`id`)
) DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- CreateTable
CREATE TABLE `financial_audit_events` (
    `id` VARCHAR(191) NOT NULL,
    `organizationId` VARCHAR(191) NOT NULL,
    `serviceOrderId` VARCHAR(191) NOT NULL,
    `actorUserId` VARCHAR(191) NULL,
    `origin` ENUM('USER_COMMAND', 'SYSTEM_DERIVED') NOT NULL,
    `eventType` VARCHAR(191) NOT NULL,
    `entityType` VARCHAR(191) NOT NULL,
    `entityId` VARCHAR(191) NOT NULL,
    `operationId` VARCHAR(191) NOT NULL,
    `ordinal` INTEGER NOT NULL,
    `occurredAt` DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `metadata` JSON NULL,

    INDEX `financial_audit_events_organizationId_idx`(`organizationId`),
    INDEX `financial_audit_events_serviceOrderId_idx`(`serviceOrderId`),
    INDEX `financial_audit_events_entityType_entityId_idx`(`entityType`, `entityId`),
    INDEX `financial_audit_events_occurredAt_idx`(`occurredAt`),
    UNIQUE INDEX `financial_audit_events_operationId_ordinal_key`(`operationId`, `ordinal`),
    PRIMARY KEY (`id`)
) DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- CreateIndex
CREATE UNIQUE INDEX `service_orders_currentQuoteRevisionId_key` ON `service_orders`(`currentQuoteRevisionId`);

-- CreateIndex
CREATE UNIQUE INDEX `service_orders_lastApprovedQuoteRevisionId_key` ON `service_orders`(`lastApprovedQuoteRevisionId`);

-- CreateIndex
CREATE INDEX `service_orders_financeCoreVersion_idx` ON `service_orders`(`financeCoreVersion`);

-- AddForeignKey
ALTER TABLE `service_orders` ADD CONSTRAINT `service_orders_currentQuoteRevisionId_fkey` FOREIGN KEY (`currentQuoteRevisionId`) REFERENCES `service_order_quote_revisions`(`id`) ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `service_orders` ADD CONSTRAINT `service_orders_lastApprovedQuoteRevisionId_fkey` FOREIGN KEY (`lastApprovedQuoteRevisionId`) REFERENCES `service_order_quote_revisions`(`id`) ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `service_order_quote_revisions` ADD CONSTRAINT `service_order_quote_revisions_serviceOrderId_fkey` FOREIGN KEY (`serviceOrderId`) REFERENCES `service_orders`(`id`) ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `service_order_quote_revisions` ADD CONSTRAINT `service_order_quote_revisions_organizationId_fkey` FOREIGN KEY (`organizationId`) REFERENCES `organizations`(`id`) ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `service_order_quote_revisions` ADD CONSTRAINT `service_order_quote_revisions_customerId_fkey` FOREIGN KEY (`customerId`) REFERENCES `customers`(`id`) ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `service_order_quote_revisions` ADD CONSTRAINT `service_order_quote_revisions_createdByUserId_fkey` FOREIGN KEY (`createdByUserId`) REFERENCES `users`(`id`) ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `customer_quote_decisions` ADD CONSTRAINT `customer_quote_decisions_quoteRevisionId_fkey` FOREIGN KEY (`quoteRevisionId`) REFERENCES `service_order_quote_revisions`(`id`) ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `customer_quote_decisions` ADD CONSTRAINT `customer_quote_decisions_serviceOrderId_fkey` FOREIGN KEY (`serviceOrderId`) REFERENCES `service_orders`(`id`) ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `customer_quote_decisions` ADD CONSTRAINT `customer_quote_decisions_organizationId_fkey` FOREIGN KEY (`organizationId`) REFERENCES `organizations`(`id`) ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `customer_quote_decisions` ADD CONSTRAINT `customer_quote_decisions_customerId_fkey` FOREIGN KEY (`customerId`) REFERENCES `customers`(`id`) ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `customer_quote_decisions` ADD CONSTRAINT `customer_quote_decisions_decidedByUserId_fkey` FOREIGN KEY (`decidedByUserId`) REFERENCES `users`(`id`) ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `receivables` ADD CONSTRAINT `receivables_organizationId_fkey` FOREIGN KEY (`organizationId`) REFERENCES `organizations`(`id`) ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `receivables` ADD CONSTRAINT `receivables_customerId_fkey` FOREIGN KEY (`customerId`) REFERENCES `customers`(`id`) ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `receivables` ADD CONSTRAINT `receivables_serviceOrderId_fkey` FOREIGN KEY (`serviceOrderId`) REFERENCES `service_orders`(`id`) ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE `receivables` ADD CONSTRAINT `receivables_sourceQuoteRevisionId_fkey` FOREIGN KEY (`sourceQuoteRevisionId`) REFERENCES `service_order_quote_revisions`(`id`) ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `receivables` ADD CONSTRAINT `receivables_createdByUserId_fkey` FOREIGN KEY (`createdByUserId`) REFERENCES `users`(`id`) ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `receivables` ADD CONSTRAINT `receivables_cancelledByUserId_fkey` FOREIGN KEY (`cancelledByUserId`) REFERENCES `users`(`id`) ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `receivable_schedules` ADD CONSTRAINT `receivable_schedules_organizationId_fkey` FOREIGN KEY (`organizationId`) REFERENCES `organizations`(`id`) ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `receivable_schedules` ADD CONSTRAINT `receivable_schedules_receivableId_fkey` FOREIGN KEY (`receivableId`) REFERENCES `receivables`(`id`) ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `receivable_schedules` ADD CONSTRAINT `receivable_schedules_createdByUserId_fkey` FOREIGN KEY (`createdByUserId`) REFERENCES `users`(`id`) ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `receivable_installments` ADD CONSTRAINT `receivable_installments_organizationId_fkey` FOREIGN KEY (`organizationId`) REFERENCES `organizations`(`id`) ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `receivable_installments` ADD CONSTRAINT `receivable_installments_receivableId_fkey` FOREIGN KEY (`receivableId`) REFERENCES `receivables`(`id`) ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `receivable_installments` ADD CONSTRAINT `receivable_installments_scheduleId_fkey` FOREIGN KEY (`scheduleId`) REFERENCES `receivable_schedules`(`id`) ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `payment_allocations` ADD CONSTRAINT `payment_allocations_organizationId_fkey` FOREIGN KEY (`organizationId`) REFERENCES `organizations`(`id`) ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `payment_allocations` ADD CONSTRAINT `payment_allocations_customerId_fkey` FOREIGN KEY (`customerId`) REFERENCES `customers`(`id`) ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `payment_allocations` ADD CONSTRAINT `payment_allocations_serviceOrderId_fkey` FOREIGN KEY (`serviceOrderId`) REFERENCES `service_orders`(`id`) ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `payment_allocations` ADD CONSTRAINT `payment_allocations_receivableId_fkey` FOREIGN KEY (`receivableId`) REFERENCES `receivables`(`id`) ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `payment_allocations` ADD CONSTRAINT `payment_allocations_installmentId_fkey` FOREIGN KEY (`installmentId`) REFERENCES `receivable_installments`(`id`) ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `payment_allocations` ADD CONSTRAINT `payment_allocations_paymentId_fkey` FOREIGN KEY (`paymentId`) REFERENCES `payments`(`id`) ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `payment_allocations` ADD CONSTRAINT `payment_allocations_createdByUserId_fkey` FOREIGN KEY (`createdByUserId`) REFERENCES `users`(`id`) ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `financial_audit_events` ADD CONSTRAINT `financial_audit_events_organizationId_fkey` FOREIGN KEY (`organizationId`) REFERENCES `organizations`(`id`) ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `financial_audit_events` ADD CONSTRAINT `financial_audit_events_serviceOrderId_fkey` FOREIGN KEY (`serviceOrderId`) REFERENCES `service_orders`(`id`) ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `financial_audit_events` ADD CONSTRAINT `financial_audit_events_actorUserId_fkey` FOREIGN KEY (`actorUserId`) REFERENCES `users`(`id`) ON DELETE RESTRICT ON UPDATE CASCADE;

-- ============================================================
-- FIN-F02 DATABASE-ENFORCED SECURITY GUARDS
-- ============================================================

ALTER TABLE `payments`
  ADD CONSTRAINT `chk_payments_card_installment_count`
  CHECK (
    `cardInstallmentCount` IS NULL
    OR (
      `method` = 'CARTAO_CREDITO'
      AND `cardInstallmentCount` BETWEEN 1 AND 24
    )
  );

ALTER TABLE `receivables`
  ADD COLUMN `activeServiceOrderGuard` VARCHAR(191)
    GENERATED ALWAYS AS (
      CASE
        WHEN `lifecycleStatus` = 'ACTIVE'
        THEN `serviceOrderId`
        ELSE NULL
      END
    ) STORED,
  ADD UNIQUE INDEX `receivables_one_active_per_service_order`
    (`activeServiceOrderGuard`);

ALTER TABLE `receivables`
  ADD CONSTRAINT `chk_receivables_total_amount`
    CHECK (`totalAmount` > 0),
  ADD CONSTRAINT `chk_receivables_current_schedule_version`
    CHECK (`currentScheduleVersion` >= 1),
  ADD CONSTRAINT `chk_receivables_version`
    CHECK (`version` >= 1);

ALTER TABLE `receivable_schedules`
  ADD CONSTRAINT `chk_receivable_schedules_version`
    CHECK (`version` >= 1);

ALTER TABLE `receivable_installments`
  ADD CONSTRAINT `chk_receivable_installments_schedule_version`
    CHECK (`scheduleVersion` >= 1),
  ADD CONSTRAINT `chk_receivable_installments_sequence`
    CHECK (`sequence` >= 1),
  ADD CONSTRAINT `chk_receivable_installments_amount`
    CHECK (`amount` > 0);

ALTER TABLE `payment_allocations`
  ADD CONSTRAINT `chk_payment_allocations_amount`
    CHECK (`amount` > 0);

ALTER TABLE `financial_audit_events`
  ADD CONSTRAINT `chk_financial_audit_events_ordinal`
    CHECK (`ordinal` >= 1);

CREATE TRIGGER `financial_audit_events_validate_insert`
BEFORE INSERT ON `financial_audit_events`
FOR EACH ROW
BEGIN
  IF NEW.`origin` = 'USER_COMMAND'
     AND NEW.`actorUserId` IS NULL THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT =
        'USER_COMMAND financial audit events require actorUserId';
  END IF;
END;

CREATE TRIGGER `financial_audit_events_no_update`
BEFORE UPDATE ON `financial_audit_events`
FOR EACH ROW
SIGNAL SQLSTATE '45000'
  SET MESSAGE_TEXT = 'financial_audit_events is append-only';

CREATE TRIGGER `financial_audit_events_no_delete`
BEFORE DELETE ON `financial_audit_events`
FOR EACH ROW
SIGNAL SQLSTATE '45000'
  SET MESSAGE_TEXT = 'financial_audit_events is append-only';