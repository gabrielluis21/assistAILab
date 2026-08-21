import {
  EquipmentConsentMethod,
  EquipmentPurpose,
} from '@prisma/client';

import {
  z,
} from 'zod';

/**
 * A aquisição C4 representa somente equipamentos
 * destinados a revenda ou aproveitamento de peças.
 *
 * INTERNAL_USE existe no domínio, mas não pertence
 * ao fluxo C4.
 */
export const createEquipmentAcquisitionSchema =
  z.object({
    equipmentId:
      z.string()
        .uuid(),

    serviceOrderId:
      z.string()
        .uuid()
        .optional(),

    purpose:
      z.nativeEnum(
        EquipmentPurpose
      )
        .refine(
          (
            value
          ) =>
            value ===
              EquipmentPurpose.RESALE ||
            value ===
              EquipmentPurpose.PARTS_DONOR,
          {
            message:
              'C4 acquisition purpose must be RESALE or PARTS_DONOR',
          }
        ),

    offeredAmount:
      z.number()
        .positive()
        .finite()
        .optional(),

    notes:
      z.string()
        .trim()
        .max(5000)
        .optional(),
  });

export const authorizeEquipmentAcquisitionSchema =
  z.object({
    consentMethod:
      z.nativeEnum(
        EquipmentConsentMethod
      ),
  });

export type CreateEquipmentAcquisitionInput =
  z.infer<
    typeof createEquipmentAcquisitionSchema
  >;

export type AuthorizeEquipmentAcquisitionInput =
  z.infer<
    typeof authorizeEquipmentAcquisitionSchema
  >;
