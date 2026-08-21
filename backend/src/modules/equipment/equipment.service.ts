import {
  EquipmentOwnerType,
} from '@prisma/client';

import {
  prisma,
} from '../../core/database/prisma.js';

import {
  CreateEquipmentInput,
  UpdateEquipmentInput,
} from './equipment.schema.js';

import {
  NotFoundError,
} from '../../core/utils/errors.js';

export class EquipmentService {
  /**
   * ========================================================
   * CUSTOMER
   * ========================================================
   *
   * Customer continua enxergando seus próprios
   * equipamentos.
   */
  async listByCustomer(
    customerId: string
  ) {
    return prisma
      .equipment
      .findMany({
        where: {
          customerId,

          ownerType:
            EquipmentOwnerType
              .CUSTOMER,
        },

        orderBy: {
          updatedAt:
            'desc',
        },
      });
  }

  /**
   * ========================================================
   * ORGANIZATION
   * ========================================================
   *
   * Uma Organization pode enxergar:
   *
   * 1. Equipment que pertence à própria Organization;
   *
   * OU
   *
   * 2. Equipment CUSTOMER-owned que já apareceu
   *    em pelo menos uma OS da Organization.
   *
   * CustomerOrganization sozinho NÃO concede acesso.
   */
  async listForOrganization(
    organizationId: string,
    customerId?: string
  ) {
    if (
      customerId
    ) {
      return prisma
        .equipment
        .findMany({
          where: {
            customerId,

            ownerType:
              EquipmentOwnerType
                .CUSTOMER,

            serviceOrders: {
              some: {
                organizationId,
              },
            },
          },

          include: {
            customer: {
              select: {
                id:
                  true,

                name:
                  true,
              },
            },
          },

          orderBy: {
            updatedAt:
              'desc',
          },
        });
    }

    return prisma
      .equipment
      .findMany({
        where: {
          OR: [
            /**
             * Equipment adquirido pela
             * própria Organization.
             */
            {
              ownerType:
                EquipmentOwnerType
                  .ORGANIZATION,

              organizationId,
            },

            /**
             * Equipment do Customer,
             * mas conhecido através
             * de OS da Organization.
             */
            {
              ownerType:
                EquipmentOwnerType
                  .CUSTOMER,

              serviceOrders: {
                some: {
                  organizationId,
                },
              },
            },
          ],
        },

        include: {
          customer: {
            select: {
              id:
                true,

              name:
                true,
            },
          },
        },

        orderBy: {
          updatedAt:
            'desc',
        },
      });
  }

  /**
   * Leitura usada pelo próprio Customer.
   */
  async findById(
    id: string
  ) {
    const equipment =
      await prisma
        .equipment
        .findUnique({
          where: {
            id,
          },

          include: {
            customer: {
              select: {
                id:
                  true,

                name:
                  true,
              },
            },

            serviceOrders: {
              select: {
                id:
                  true,

                status:
                  true,

                updatedAt:
                  true,
              },

              take:
                10,
            },
          },
        });

    if (
      !equipment
    ) {
      throw new NotFoundError(
        `Equipment ${id} not found`
      );
    }

    return equipment;
  }

  /**
   * ========================================================
   * ORGANIZATION-SCOPED GET
   * ========================================================
   *
   * Importante:
   *
   * mesmo quando a Organization pode ver o
   * Equipment, ela recebe apenas as próprias OS.
   *
   * Isso impede vazamento:
   *
   * Assistência A
   *   Equipment
   *     OS A ✅
   *     OS B ❌
   */
  async findByIdForOrganization(
    id: string,
    organizationId: string
  ) {
    const equipment =
      await prisma
        .equipment
        .findFirst({
          where: {
            id,

            OR: [
              {
                ownerType:
                  EquipmentOwnerType
                    .ORGANIZATION,

                organizationId,
              },

              {
                ownerType:
                  EquipmentOwnerType
                    .CUSTOMER,

                serviceOrders: {
                  some: {
                    organizationId,
                  },
                },
              },
            ],
          },

          include: {
            customer: {
              select: {
                id:
                  true,

                name:
                  true,
              },
            },

            /**
             * Fundamental:
             *
             * não retornar OS de outras
             * Organizations.
             */
            serviceOrders: {
              where: {
                organizationId,
              },

              select: {
                id:
                  true,

                status:
                  true,

                updatedAt:
                  true,
              },

              orderBy: {
                updatedAt:
                  'desc',
              },

              take:
                10,
            },
          },
        });

    if (
      !equipment
    ) {
      throw new NotFoundError(
        `Equipment ${id} not found`
      );
    }

    return equipment;
  }

  /**
   * Mantido temporariamente para compatibilidade
   * interna.
   *
   * O endpoint público de equipe deixará de
   * utilizar este método para criação.
   */
  async upsert(
    data:
      CreateEquipmentInput
  ) {
    return prisma
      .equipment
      .upsert({
        where: {
          id:
            data.id,
        },

        create: {
          id:
            data.id,

          customerId:
            data.customerId,

          type:
            data.type,

          brand:
            data.brand,

          model:
            data.model,

          serialNumber:
            data.serialNumber,

          notes:
            data.notes,
        },

        update: {
          type:
            data.type,

          brand:
            data.brand,

          model:
            data.model,

          serialNumber:
            data.serialNumber,

          notes:
            data.notes,

          updatedAt:
            new Date(),
        },
      });
  }

  /**
   * ========================================================
   * UPDATE SCOPED
   * ========================================================
   */
  async updateForOrganization(
    id: string,
    organizationId: string,
    data:
      UpdateEquipmentInput
  ) {
    const existing =
      await prisma
        .equipment
        .findFirst({
          where: {
            id,

            OR: [
              {
                ownerType:
                  EquipmentOwnerType
                    .ORGANIZATION,

                organizationId,
              },

              {
                ownerType:
                  EquipmentOwnerType
                    .CUSTOMER,

                serviceOrders: {
                  some: {
                    organizationId,
                  },
                },
              },
            ],
          },

          select: {
            id:
              true,
          },
        });

    if (
      !existing
    ) {
      throw new NotFoundError(
        `Equipment ${id} not found`
      );
    }

    return prisma
      .equipment
      .update({
        where: {
          id,
        },

        data: {
          ...data,

          updatedAt:
            new Date(),
        },
      });
  }

  /**
   * ========================================================
   * DELETE SCOPED
   * ========================================================
   */
  async deleteForOrganization(
    id: string,
    organizationId: string
  ) {
    const existing =
      await prisma
        .equipment
        .findFirst({
          where: {
            id,

            OR: [
              {
                ownerType:
                  EquipmentOwnerType
                    .ORGANIZATION,

                organizationId,
              },

              {
                ownerType:
                  EquipmentOwnerType
                    .CUSTOMER,

                serviceOrders: {
                  some: {
                    organizationId,
                  },
                },
              },
            ],
          },

          select: {
            id:
              true,
          },
        });

    if (
      !existing
    ) {
      throw new NotFoundError(
        `Equipment ${id} not found`
      );
    }

    return prisma
      .equipment
      .delete({
        where: {
          id,
        },
      });
  }
}