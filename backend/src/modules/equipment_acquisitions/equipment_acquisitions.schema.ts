import {
  AcquisitionSource,
  EquipmentConsentMethod,
  EquipmentPurpose,
} from '@prisma/client';
import { z } from 'zod';

import {
  DECIMAL_10_2_MAX_MINOR,
  serviceOrderMoneyMinorSchema,
} from '../../core/money/money.js';

const acquisitionPurposeSchema = z.nativeEnum(EquipmentPurpose).refine(
  value => value === EquipmentPurpose.RESALE || value === EquipmentPurpose.PARTS_DONOR,
  { message: 'Acquisition purpose must be RESALE or PARTS_DONOR' }
);

const offeredAmountMinorSchema = serviceOrderMoneyMinorSchema
  .min(1)
  .max(DECIMAL_10_2_MAX_MINOR);

const commonCreateShape = {
  equipmentId: z.string().uuid(),
  purpose: acquisitionPurposeSchema,
  offeredAmountMinor: offeredAmountMinorSchema.optional(),
  notes: z.string().trim().max(5000).optional(),
  clientPreAcquisitionId: z.string().uuid().optional(),
};

export const createEquipmentAcquisitionSchema = z.object({
  ...commonCreateShape,
  source: z.literal(AcquisitionSource.SERVICE_ORDER),
  serviceOrderId: z.string().uuid(),
}).strict();

export const createDirectOfferSchema = z.object({
  ...commonCreateShape,
  source: z.literal(AcquisitionSource.DIRECT_OFFER),
}).strict();

export const authorizeEquipmentAcquisitionSchema = z.object({
  consentMethod: z.nativeEnum(EquipmentConsentMethod).refine(
    value => value !== EquipmentConsentMethod.IN_PERSON_ASSISTED,
    { message: 'IN_PERSON_ASSISTED is exclusive to direct in-person authorization' }
  ),
}).strict();

export const authorizeInPersonSchema = z.object({
  consentMethod: z.literal(EquipmentConsentMethod.IN_PERSON_ASSISTED),
}).strict();

export const emptyAcquisitionMutationSchema = z.object({}).strict();

export type CreateEquipmentAcquisitionInput = z.infer<typeof createEquipmentAcquisitionSchema>;
export type CreateDirectOfferInput = z.infer<typeof createDirectOfferSchema>;
export type AuthorizeEquipmentAcquisitionInput = z.infer<typeof authorizeEquipmentAcquisitionSchema>;
export type AuthorizeInPersonInput = z.infer<typeof authorizeInPersonSchema>;
