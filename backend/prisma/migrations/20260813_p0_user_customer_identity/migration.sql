-- AlterTable: Add customerId to users (nullable, unique FK to customers.id)
-- Migration: p0_user_customer_identity
-- Non-destructive: existing rows keep customerId = NULL.
-- ADMIN/TECHNICIAN users: customerId = NULL.
-- CUSTOMER users: customerId -> customers.id (linked explicitly).

ALTER TABLE `users`
  ADD COLUMN `customerId` VARCHAR(191) NULL,
  ADD UNIQUE INDEX `users_customerId_key` (`customerId`),
  ADD CONSTRAINT `users_customerId_fkey`
    FOREIGN KEY (`customerId`) REFERENCES `customers` (`id`)
    ON DELETE SET NULL ON UPDATE CASCADE;
