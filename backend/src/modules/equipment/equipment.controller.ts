import {
  FastifyRequest,
  FastifyReply,
} from 'fastify';

import {
  updateEquipmentSchema,
} from './equipment.schema.js';

import {
  EquipmentService,
} from './equipment.service.js';

import {
  getAuthUser,
  requireOrganizationId,
} from '../../core/middleware/auth.middleware.js';

import {
  ForbiddenError,
} from '../../core/utils/errors.js';

const svc =
  new EquipmentService();

/**
 * ============================================================
 * LIST
 * ============================================================
 */
export async function listEquipmentsHandler(
  req: FastifyRequest,
  reply: FastifyReply
) {
  const authUser =
    getAuthUser(
      req
    );

  /**
   * Customer vê seus próprios equipamentos.
   */
  if (
    authUser.role ===
    'CUSTOMER'
  ) {
    if (
      !authUser.customerId
    ) {
      throw new ForbiddenError(
        'Access denied: no customer identity associated with this account'
      );
    }

    const data =
      await svc
        .listByCustomer(
          authUser.customerId
        );

    return reply.send(
      data
    );
  }

  /**
   * ADMIN / TECH:
   *
   * somente Equipment:
   *
   * - da própria Organization;
   * - ou usado em OS da Organization.
   */
  const {
    customerId,
  } =
    req.query as {
      customerId?: string;
    };

  const data =
    await svc
      .listForOrganization(
        authUser.organizationId,
        customerId
      );

  return reply.send(
    data
  );
}

/**
 * ============================================================
 * GET
 * ============================================================
 */
export async function getEquipmentHandler(
  req: FastifyRequest,
  reply: FastifyReply
) {
  const {
    id,
  } =
    req.params as {
      id: string;
    };

  const authUser =
    getAuthUser(
      req
    );

  /**
   * CUSTOMER.
   */
  if (
    authUser.role ===
    'CUSTOMER'
  ) {
    const equipment =
      await svc
        .findById(
          id
        );

    if (
      !authUser.customerId ||
      equipment.customerId !==
      authUser.customerId
    ) {
      throw new ForbiddenError(
        'Access denied: you can only access your own equipment'
      );
    }

    return reply.send(
      equipment
    );
  }

  /**
   * ADMIN / TECH.
   */
  const equipment =
    await svc
      .findByIdForOrganization(
        id,
        authUser.organizationId
      );

  return reply.send(
    equipment
  );
}

/**
 * ============================================================
 * CREATE / UPSERT
 * ============================================================
 *
 * A equipe NÃO cria mais Equipment CUSTOMER isoladamente.
 *
 * Primeiro cadastro:
 *
 * POST /service-orders
 *
 * Futuramente Equipment ORGANIZATION será criado pelo
 * fluxo EquipmentAcquisition.
 */
export async function upsertEquipmentHandler(
  _req: FastifyRequest,
  _reply: FastifyReply
) {
  throw new ForbiddenError(
    'Equipment must be registered through a Service Order or an approved acquisition flow'
  );
}

/**
 * ============================================================
 * UPDATE
 * ============================================================
 */
export async function updateEquipmentHandler(
  req: FastifyRequest,
  reply: FastifyReply
) {
  const {
    id,
  } =
    req.params as {
      id: string;
    };

  const authUser =
    getAuthUser(
      req
    );

  const body =
    updateEquipmentSchema.parse(
      req.body
    );

  const equipment =
    await svc
      .updateForOrganization(
        id,
        authUser.organizationId,
        body
      );

  return reply.send(
    equipment
  );
}

/**
 * ============================================================
 * DELETE
 * ============================================================
 */
export async function deleteEquipmentHandler(
  req: FastifyRequest,
  reply: FastifyReply
) {
  const {
    id,
  } =
    req.params as {
      id: string;
    };

  const authUser =
    getAuthUser(
      req
    );

  await svc
    .deleteForOrganization(
      id,
      authUser.organizationId
    );

  return reply
    .status(204)
    .send();
}