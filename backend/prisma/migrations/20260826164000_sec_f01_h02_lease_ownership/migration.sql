-- SEC-F01-H02 — Idempotency Lease Ownership / Fencing
ALTER TABLE `operation_idempotency`
  ADD COLUMN `leaseToken` VARCHAR(191) NULL;
