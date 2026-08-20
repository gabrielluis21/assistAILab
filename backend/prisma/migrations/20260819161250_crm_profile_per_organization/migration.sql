/*
  Warnings:

  - You are about to drop the column `customerId` on the `customer_profiles` table. All the data in the column will be lost.
  - A unique constraint covering the columns `[customerOrganizationId]` on the table `customer_profiles` will be added. If there are existing duplicate values, this will fail.
  - Added the required column `customerOrganizationId` to the `customer_profiles` table without a default value. This is not possible if the table is not empty.

*/
-- DropForeignKey
ALTER TABLE `customer_profiles` DROP FOREIGN KEY `customer_profiles_customerId_fkey`;

-- DropIndex
DROP INDEX `customer_profiles_customerId_key` ON `customer_profiles`;

-- AlterTable
ALTER TABLE `customer_profiles` DROP COLUMN `customerId`,
    ADD COLUMN `customerOrganizationId` VARCHAR(191) NOT NULL;

-- CreateIndex
CREATE UNIQUE INDEX `customer_profiles_customerOrganizationId_key` ON `customer_profiles`(`customerOrganizationId`);

-- AddForeignKey
ALTER TABLE `customer_profiles` ADD CONSTRAINT `customer_profiles_customerOrganizationId_fkey` FOREIGN KEY (`customerOrganizationId`) REFERENCES `customer_organizations`(`id`) ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE `customer_feedbacks` ADD CONSTRAINT `customer_feedbacks_organizationId_fkey` FOREIGN KEY (`organizationId`) REFERENCES `organizations`(`id`) ON DELETE CASCADE ON UPDATE CASCADE;
