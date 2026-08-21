import {
  createHash,
} from 'node:crypto';

import {
  EquipmentAcquisitionStatus,
  EquipmentOwnerType,
  EquipmentPurpose,
} from '@prisma/client';

import {
  prisma,
} from '../../core/database/prisma.js';

import {
  ConflictError,
  NotFoundError,
} from '../../core/utils/errors.js';

import type {
  AuthorizeEquipmentAcquisitionInput,
  CreateEquipmentAcquisitionInput,
} from './equipment_acquisitions.schema.js';

function hashConsentSnapshot(
  snapshot: Record<string, unknown>
): string {
  return createHash(
    'sha256'
  )
    .update(
      JSON.stringify(
        snapshot
      )
    )
    .digest(
      'hex'
    );
}

const acquisitionInclude = {
  equipment: {
    select: {
      id:
        true,
      ownerType:
        true,
      customerId:
        true,
      organizationId:
        true,
      organizationPurpose:
        true,
      type:
        true,
      brand:
        true,
      model:
        true,
      serialNumber:
        true,
    },
  },

  customer: {
    select: {
      id:
        true,
      name:
        true,
    },
  },

  organization: {
    select: {
      id:
        true,
      name:
        true,
    },
  },

  serviceOrder: {
    select: {
      id:
        true,
      friendlyId:
        true,
      status:
        true,
    },
  },
} as const;

export class EquipmentAcquisitionService {
  /**
   * ========================================================
   * CREATE PROPOSAL
   * ========================================================
   *
   * A Organization somente pode propor aquisição
   * de Equipment CUSTOMER que já conhece através
   * de uma ServiceOrder própria.
   *
   * Criar a proposta NÃO transfere ownership.
   */
  async createProposal(
    input:
      CreateEquipmentAcquisitionInput,
    organizationId:
      string
  ) {
    const equipment =
      await prisma
        .equipment
        .findFirst({
          where: {
            id:
              input.equipmentId,

            ownerType:
              EquipmentOwnerType
                .CUSTOMER,

            customerId: {
              not:
                null,
            },

            serviceOrders: {
              some: {
                organizationId,
              },
            },
          },

          select: {
            id:
              true,

            customerId:
              true,
          },
        });

    if (
      !equipment ||
      !equipment.customerId
    ) {
      throw new NotFoundError(
        'Customer-owned Equipment is not available to the current organization'
      );
    }

    /**
     * Quando a proposta aponta explicitamente
     * para uma OS, ela precisa corresponder:
     *
     * Organization + Customer + Equipment.
     */
    if (
      input.serviceOrderId
    ) {
      const order =
        await prisma
          .serviceOrder
          .findFirst({
            where: {
              id:
                input.serviceOrderId,

              organizationId,

              customerId:
                equipment.customerId,

              equipmentId:
                equipment.id,
            },

            select: {
              id:
                true,
            },
          });

      if (!order) {
        throw new NotFoundError(
          'Service Order is not available for this acquisition'
        );
      }
    }

    /**
     * Evita duas propostas simultaneamente
     * disputando o mesmo Equipment.
     */
    const activeAcquisition =
      await prisma
        .equipmentAcquisition
        .findFirst({
          where: {
            equipmentId:
              equipment.id,

            status: {
              in: [
                EquipmentAcquisitionStatus
                  .PENDING,

                EquipmentAcquisitionStatus
                  .AUTHORIZED,
              ],
            },
          },

          select: {
            id:
              true,
          },
        });

    if (
      activeAcquisition
    ) {
      throw new ConflictError(
        'Equipment already has an active acquisition proposal'
      );
    }

    return prisma
      .equipmentAcquisition
      .create({
        data: {
          equipmentId:
            equipment.id,

          customerId:
            equipment.customerId,

          organizationId,

          serviceOrderId:
            input.serviceOrderId,

          purpose:
            input.purpose,

          offeredAmount:
            input.offeredAmount,

          notes:
            input.notes,

          status:
            EquipmentAcquisitionStatus
              .PENDING,
        },

        include:
          acquisitionInclude,
      });
  }

  /**
   * ========================================================
   * READ
   * ========================================================
   */
  async listForOrganization(
    organizationId:
      string
  ) {
    return prisma
      .equipmentAcquisition
      .findMany({
        where: {
          organizationId,
        },

        include:
          acquisitionInclude,

        orderBy: {
          createdAt:
            'desc',
        },
      });
  }

  async listForCustomer(
    customerId:
      string
  ) {
    return prisma
      .equipmentAcquisition
      .findMany({
        where: {
          customerId,
        },

        include:
          acquisitionInclude,

        orderBy: {
          createdAt:
            'desc',
        },
      });
  }

  async findForOrganization(
    id:
      string,
    organizationId:
      string
  ) {
    const acquisition =
      await prisma
        .equipmentAcquisition
        .findFirst({
          where: {
            id,
            organizationId,
          },

          include:
            acquisitionInclude,
        });

    if (!acquisition) {
      throw new NotFoundError(
        'Equipment acquisition not found'
      );
    }

    return acquisition;
  }

  async findForCustomer(
    id:
      string,
    customerId:
      string
  ) {
    const acquisition =
      await prisma
        .equipmentAcquisition
        .findFirst({
          where: {
            id,
            customerId,
          },

          include:
            acquisitionInclude,
        });

    if (!acquisition) {
      throw new NotFoundError(
        'Equipment acquisition not found'
      );
    }

    return acquisition;
  }

  /**
   * ========================================================
   * CUSTOMER AUTHORIZE
   * ========================================================
   *
   * O Customer aceita exatamente a proposta
   * já apresentada.
   *
   * purpose / amount não vêm neste endpoint.
   */
  async authorize(
    id:
      string,
    customerId:
      string,
    userId:
      string,
    input:
      AuthorizeEquipmentAcquisitionInput
  ) {
    const acquisition =
      await prisma
        .equipmentAcquisition
        .findFirst({
          where: {
            id,
            customerId,
          },
        });

    if (!acquisition) {
      throw new NotFoundError(
        'Equipment acquisition not found'
      );
    }

    /**
     * Retry idempotente.
     */
    if (
      acquisition.status ===
      EquipmentAcquisitionStatus
        .AUTHORIZED
    ) {
      return this
        .findForCustomer(
          id,
          customerId
        );
    }

    if (
      acquisition.status !==
      EquipmentAcquisitionStatus
        .PENDING
    ) {
      throw new ConflictError(
        'Only a pending acquisition can be authorized'
      );
    }

    const authorizedAt =
      new Date();

    /**
     * Snapshot produzido pelo backend.
     *
     * O client não escolhe Equipment, Customer,
     * Organization, purpose ou offeredAmount
     * durante o aceite.
     */
    const consentSnapshot = {
      acquisitionId:
        acquisition.id,

      equipmentId:
        acquisition.equipmentId,

      customerId:
        acquisition.customerId,

      organizationId:
        acquisition.organizationId,

      serviceOrderId:
        acquisition.serviceOrderId,

      purpose:
        acquisition.purpose,

      offeredAmount:
        acquisition.offeredAmount
          ?.toString() ??
        null,

      consentMethod:
        input.consentMethod,

      authorizedByUserId:
        userId,

      authorizedAt:
        authorizedAt
          .toISOString(),
    };

    const consentHash =
      hashConsentSnapshot(
        consentSnapshot
      );

    const updated =
      await prisma
        .equipmentAcquisition
        .updateMany({
          where: {
            id:
              acquisition.id,

            customerId,

            status:
              EquipmentAcquisitionStatus
                .PENDING,
          },

          data: {
            status:
              EquipmentAcquisitionStatus
                .AUTHORIZED,

            consentMethod:
              input.consentMethod,

            consentSnapshot,

            consentHash,

            authorizedAt,
          },
        });

    if (
      updated.count !==
      1
    ) {
      throw new ConflictError(
        'Equipment acquisition is no longer pending'
      );
    }

    return this
      .findForCustomer(
        id,
        customerId
      );
  }

  /**
   * ========================================================
   * CUSTOMER REJECT
   * ========================================================
   */
  async reject(
    id:
      string,
    customerId:
      string
  ) {
    const acquisition =
      await prisma
        .equipmentAcquisition
        .findFirst({
          where: {
            id,
            customerId,
          },
        });

    if (!acquisition) {
      throw new NotFoundError(
        'Equipment acquisition not found'
      );
    }

    /**
     * Retry idempotente.
     */
    if (
      acquisition.status ===
      EquipmentAcquisitionStatus
        .REJECTED
    ) {
      return this
        .findForCustomer(
          id,
          customerId
        );
    }

    if (
      acquisition.status !==
      EquipmentAcquisitionStatus
        .PENDING
    ) {
      throw new ConflictError(
        'Only a pending acquisition can be rejected'
      );
    }

    const updated =
      await prisma
        .equipmentAcquisition
        .updateMany({
          where: {
            id:
              acquisition.id,

            customerId,

            status:
              EquipmentAcquisitionStatus
                .PENDING,
          },

          data: {
            status:
              EquipmentAcquisitionStatus
                .REJECTED,

            rejectedAt:
              new Date(),
          },
        });

    if (
      updated.count !==
      1
    ) {
      throw new ConflictError(
        'Equipment acquisition is no longer pending'
      );
    }

    return this
      .findForCustomer(
        id,
        customerId
      );
  }

  /**
   * ========================================================
   * COMPLETE / OWNERSHIP TRANSFER
   * ========================================================
   *
   * ÚNICO ponto do C4 que altera:
   *
   * EquipmentOwnerType.CUSTOMER
   *              ↓
   * EquipmentOwnerType.ORGANIZATION
   */
  async complete(
    id:
      string,
    organizationId:
      string
  ) {
    return prisma
      .$transaction(
        async (
          tx
        ) => {
          const acquisition =
            await tx
              .equipmentAcquisition
              .findFirst({
                where: {
                  id,
                  organizationId,
                },
              });

          if (!acquisition) {
            throw new NotFoundError(
              'Equipment acquisition not found'
            );
          }

          /**
           * Retry idempotente.
           */
          if (
            acquisition.status ===
            EquipmentAcquisitionStatus
              .COMPLETED
          ) {
            return tx
              .equipmentAcquisition
              .findUniqueOrThrow({
                where: {
                  id:
                    acquisition.id,
                },

                include:
                  acquisitionInclude,
              });
          }

          /**
           * PENDING / REJECTED / CANCELLED
           * jamais transferem ownership.
           */
          if (
            acquisition.status !==
            EquipmentAcquisitionStatus
              .AUTHORIZED
          ) {
            throw new ConflictError(
              'Only an authorized acquisition can be completed'
            );
          }

          /**
           * AUTHORIZED precisa conter evidência
           * mínima de consentimento.
           */
          if (
            !acquisition
              .authorizedAt ||
            !acquisition
              .consentMethod ||
            !acquisition
              .consentHash
          ) {
            throw new ConflictError(
              'Authorized acquisition has no valid consent evidence'
            );
          }

          /**
           * Reserva a transição.
           *
           * Se duas requisições tentarem completar
           * ao mesmo tempo, apenas uma avança.
           */
          const reservation =
            await tx
              .equipmentAcquisition
              .updateMany({
                where: {
                  id:
                    acquisition.id,

                  organizationId,

                  status:
                    EquipmentAcquisitionStatus
                      .AUTHORIZED,
                },

                data: {
                  status:
                    EquipmentAcquisitionStatus
                      .COMPLETED,

                  completedAt:
                    new Date(),
                },
              });

          if (
            reservation.count !==
            1
          ) {
            throw new ConflictError(
              'Equipment acquisition is no longer authorized'
            );
          }

          /**
           * Transfere o Equipment somente se
           * ele ainda pertencer ao Customer
           * original da proposta.
           */
          const transferred =
            await tx
              .equipment
              .updateMany({
                where: {
                  id:
                    acquisition.equipmentId,

                  ownerType:
                    EquipmentOwnerType
                      .CUSTOMER,

                  customerId:
                    acquisition.customerId,
                },

                data: {
                  ownerType:
                    EquipmentOwnerType
                      .ORGANIZATION,

                  customerId:
                    null,

                  organizationId,

                  organizationPurpose:
                    acquisition.purpose,
                },
              });

          if (
            transferred.count !==
            1
          ) {
            throw new ConflictError(
              'Equipment ownership changed before acquisition completion'
            );
          }

          return tx
            .equipmentAcquisition
            .findUniqueOrThrow({
              where: {
                id:
                  acquisition.id,
              },

              include:
                acquisitionInclude,
            });
        }
      );
  }
}
