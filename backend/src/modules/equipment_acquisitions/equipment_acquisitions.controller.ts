import {
  FastifyReply,
  FastifyRequest,
} from 'fastify';

import {
  ForbiddenError,
} from '../../core/utils/errors.js';

import {
  getAuthUser,
  requireOrganizationId,
} from '../../core/middleware/auth.middleware.js';

import {
  authorizeEquipmentAcquisitionSchema,
  createEquipmentAcquisitionSchema,
} from './equipment_acquisitions.schema.js';

import {
  EquipmentAcquisitionService,
} from './equipment_acquisitions.service.js';

const service =
  new EquipmentAcquisitionService();

function requireCustomerId(
  request:
    FastifyRequest
): string {
  const authUser =
    getAuthUser(
      request
    );

  if (
    authUser.role !==
      'CUSTOMER' ||
    !authUser.customerId
  ) {
    throw new ForbiddenError(
      'Customer identity is required'
    );
  }

  return authUser.customerId;
}

/**
 * ============================================================
 * LIST
 * ============================================================
 */
export async function listEquipmentAcquisitionsHandler(
  request:
    FastifyRequest,
  reply:
    FastifyReply
) {
  const authUser =
    getAuthUser(
      request
    );

  if (
    authUser.role ===
    'CUSTOMER'
  ) {
    const customerId =
      requireCustomerId(
        request
      );

    const acquisitions =
      await service
        .listForCustomer(
          customerId
        );

    return reply.send({
      acquisitions,
    });
  }

  const organizationId =
    requireOrganizationId(
      authUser
    );

  const acquisitions =
    await service
      .listForOrganization(
        organizationId
      );

  return reply.send({
    acquisitions,
  });
}

/**
 * ============================================================
 * GET
 * ============================================================
 */
export async function getEquipmentAcquisitionHandler(
  request:
    FastifyRequest,
  reply:
    FastifyReply
) {
  const {
    id,
  } =
    request.params as {
      id: string;
    };

  const authUser =
    getAuthUser(
      request
    );

  if (
    authUser.role ===
    'CUSTOMER'
  ) {
    const customerId =
      requireCustomerId(
        request
      );

    const acquisition =
      await service
        .findForCustomer(
          id,
          customerId
        );

    return reply.send({
      acquisition,
    });
  }

  const organizationId =
    requireOrganizationId(
      authUser
    );

  const acquisition =
    await service
      .findForOrganization(
        id,
        organizationId
      );

  return reply.send({
    acquisition,
  });
}

/**
 * ============================================================
 * CREATE PROPOSAL — ADMIN / TECH
 * ============================================================
 */
export async function createEquipmentAcquisitionHandler(
  request:
    FastifyRequest,
  reply:
    FastifyReply
) {
  const authUser =
    getAuthUser(
      request
    );

  const organizationId =
    requireOrganizationId(
      authUser
    );

  const body =
    createEquipmentAcquisitionSchema
      .parse(
        request.body
      );

  const acquisition =
    await service
      .createProposal(
        body,
        organizationId
      );

  return reply
    .status(
      201
    )
    .send({
      acquisition,
    });
}

/**
 * ============================================================
 * AUTHORIZE — CUSTOMER
 * ============================================================
 */
export async function authorizeEquipmentAcquisitionHandler(
  request:
    FastifyRequest,
  reply:
    FastifyReply
) {
  const {
    id,
  } =
    request.params as {
      id: string;
    };

  const authUser =
    getAuthUser(
      request
    );

  const customerId =
    requireCustomerId(
      request
    );

  const body =
    authorizeEquipmentAcquisitionSchema
      .parse(
        request.body
      );

  const acquisition =
    await service
      .authorize(
        id,
        customerId,
        authUser.sub,
        body
      );

  return reply.send({
    acquisition,
  });
}

/**
 * ============================================================
 * REJECT — CUSTOMER
 * ============================================================
 */
export async function rejectEquipmentAcquisitionHandler(
  request:
    FastifyRequest,
  reply:
    FastifyReply
) {
  const {
    id,
  } =
    request.params as {
      id: string;
    };

  const customerId =
    requireCustomerId(
      request
    );

  const acquisition =
    await service
      .reject(
        id,
        customerId
      );

  return reply.send({
    acquisition,
  });
}

/**
 * ============================================================
 * COMPLETE — ADMIN / TECH
 * ============================================================
 */
export async function completeEquipmentAcquisitionHandler(
  request:
    FastifyRequest,
  reply:
    FastifyReply
) {
  const {
    id,
  } =
    request.params as {
      id: string;
    };

  const authUser =
    getAuthUser(
      request
    );

  const organizationId =
    requireOrganizationId(
      authUser
    );

  const acquisition =
    await service
      .complete(
        id,
        organizationId
      );

  return reply.send({
    acquisition,
  });
}
