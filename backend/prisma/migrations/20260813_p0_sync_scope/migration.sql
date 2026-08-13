-- Migration: p0_sync_scope
-- Purpose: persist customer ownership scope on each change-log entry.
-- Pull Sync can then filter in MySQL BEFORE pagination.

ALTER TABLE `sync_change_logs`
  ADD COLUMN `scopeCustomerId` VARCHAR(191) NULL;

CREATE INDEX `sync_change_logs_scopeCustomerId_id_idx`
  ON `sync_change_logs` (`scopeCustomerId`, `id`);

-- Backfill historical customer-owned changes where the target still exists.
UPDATE `sync_change_logs` scl
LEFT JOIN `customers` c
  ON scl.entityType = 'CUSTOMER' AND c.id = scl.entityId
LEFT JOIN `equipments` e
  ON scl.entityType = 'EQUIPMENT' AND e.id = scl.entityId
LEFT JOIN `service_orders` so
  ON scl.entityType = 'SERVICE_ORDER' AND so.id = scl.entityId
LEFT JOIN `service_order_items` soi
  ON scl.entityType = 'SERVICE_ORDER_ITEM' AND soi.id = scl.entityId
LEFT JOIN `service_orders` soi_so
  ON scl.entityType = 'SERVICE_ORDER_ITEM' AND soi_so.id = soi.serviceOrderId
LEFT JOIN `payments` p
  ON scl.entityType = 'PAYMENT' AND p.id = scl.entityId
SET scl.scopeCustomerId = CASE
  WHEN scl.entityType = 'CUSTOMER' THEN c.id
  WHEN scl.entityType = 'EQUIPMENT' THEN e.customerId
  WHEN scl.entityType = 'SERVICE_ORDER' THEN so.customerId
  WHEN scl.entityType = 'SERVICE_ORDER_ITEM' THEN soi_so.customerId
  WHEN scl.entityType = 'PAYMENT' THEN p.customerId
  ELSE NULL
END
WHERE scl.scopeCustomerId IS NULL;
