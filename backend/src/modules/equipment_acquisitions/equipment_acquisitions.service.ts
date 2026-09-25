import {
  AcquisitionSource,
  CustomerEventType,
  EquipmentAcquisitionStatus,
  EquipmentConsentMethod,
  EquipmentOwnerType,
  Prisma,
} from '@prisma/client';

import { prisma } from '../../core/database/prisma.js';
import { syncTransaction } from '../../core/database/sync_transaction.js';
import {
  resolveLiveAuthority,
  type ValidatedPrincipal,
} from '../../core/auth/live_authority.service.js';
import { computeCanonicalHash } from '../../core/idempotency/canonical_json.js';
import {
  IdempotencyService,
  IdempotencyStateConflictError,
} from '../../core/idempotency/idempotency.service.js';
import {
  decimalToMinorUnits,
  DECIMAL_10_2_MAX_MINOR,
  minorUnitsToDecimal,
} from '../../core/money/money.js';
import {
  ConflictError,
  ForbiddenError,
  NotFoundError,
} from '../../core/utils/errors.js';

import type {
  AuthorizeEquipmentAcquisitionInput,
  AuthorizeInPersonInput,
  CreateDirectOfferInput,
  CreateEquipmentAcquisitionInput,
} from './equipment_acquisitions.schema.js';

export type AcquisitionCommandResult = {
  statusCode: number;
  body: Prisma.InputJsonValue;
};

type CommandIdentity = {
  operationId: string;
  organizationId: string;
  actorUserId: string;
  command: string;
  endpoint: string;
  requestHash: string;
};

type CreateInput = CreateEquipmentAcquisitionInput | CreateDirectOfferInput;

const acquisitionInclude = {
  equipment: {
    select: {
      id: true,
      ownerType: true,
      customerId: true,
      organizationId: true,
      organizationPurpose: true,
      type: true,
      brand: true,
      model: true,
      serialNumber: true,
    },
  },
  customer: { select: { id: true, name: true } },
  organization: { select: { id: true, name: true } },
  serviceOrder: { select: { id: true, friendlyId: true, status: true } },
} as const;

function jsonValue(value: unknown): Prisma.InputJsonValue {
  return JSON.parse(JSON.stringify(value)) as Prisma.InputJsonValue;
}

function acquisitionResponse<
  T extends {
    offeredAmount: Prisma.Decimal | null;
    activeEquipmentGuard: string | null;
  },
>(acquisition: T) {
  const { offeredAmount, activeEquipmentGuard: _activeGuard, ...publicFields } = acquisition;
  return {
    ...publicFields,
    offeredAmountMinor: offeredAmount === null
      ? null
      : decimalToMinorUnits(offeredAmount, DECIMAL_10_2_MAX_MINOR),
  };
}

function assertStaff(principal: ValidatedPrincipal, organizationId: string): void {
  if (
    !['ADMIN', 'TECHNICIAN'].includes(principal.role) ||
    principal.organizationId !== organizationId
  ) {
    throw new ForbiddenError();
  }
}

function assertCustomer(principal: ValidatedPrincipal, customerId: string): void {
  if (principal.role !== 'CUSTOMER' || principal.customerId !== customerId) {
    throw new ForbiddenError();
  }
}

type CommandReservation =
  | { kind: 'REPLAY'; result: AcquisitionCommandResult }
  | { kind: 'ACQUIRED'; leaseToken: string };

async function reserve(identity: CommandIdentity): Promise<CommandReservation> {
  let result;
  try {
    result = await new IdempotencyService(prisma).reserveOrReplay(identity);
  } catch (error) {
    if (error instanceof IdempotencyStateConflictError) {
      throw new ConflictError('IDEMPOTENCY_STATE_CONFLICT');
    }
    throw error;
  }
  if (result.kind === 'REPLAY') {
    return {
      kind: 'REPLAY',
      result: {
        statusCode: result.responseStatus,
        body: result.responseBody as Prisma.InputJsonValue,
      },
    };
  }
  if (result.kind === 'KEY_REUSE') throw new ConflictError('IDEMPOTENCY_KEY_REUSE');
  if (result.kind === 'IN_PROGRESS') throw new ConflictError('IDEMPOTENCY_IN_PROGRESS');
  return { kind: 'ACQUIRED', leaseToken: result.leaseToken };
}

async function completeIdempotency(
  tx: Prisma.TransactionClient,
  identity: CommandIdentity,
  leaseToken: string,
  statusCode: number,
  body: Prisma.InputJsonValue
): Promise<AcquisitionCommandResult> {
  try {
    await IdempotencyService.completeWithinTransaction(tx, {
      ...identity,
      leaseToken,
      responseStatus: statusCode,
      responseBody: body,
    });
  } catch (error) {
    if (error instanceof IdempotencyStateConflictError) {
      throw new ConflictError('IDEMPOTENCY_STATE_CONFLICT');
    }
    throw error;
  }
  return { statusCode, body };
}

async function appendAudit(
  tx: Prisma.TransactionClient,
  acquisition: {
    id: string;
    customerId: string;
    organizationId: string;
    equipmentId: string;
    serviceOrderId: string | null;
    source: AcquisitionSource;
  },
  action: 'CREATE' | 'AUTHORIZE' | 'REJECT' | 'COMPLETE',
  actorUserId: string
): Promise<void> {
  await tx.customerEvent.create({
    data: {
      customerId: acquisition.customerId,
      organizationId: acquisition.organizationId,
      serviceOrderId: acquisition.serviceOrderId,
      type: CustomerEventType.OTHER,
      title: `Equipment acquisition ${action}`,
      description: `Equipment acquisition ${action.toLowerCase()} event`,
      metadata: {
        action,
        acquisitionId: acquisition.id,
        organizationId: acquisition.organizationId,
        customerId: acquisition.customerId,
        equipmentId: acquisition.equipmentId,
        source: acquisition.source,
        actorUserId,
      },
    },
  });
}

function consentSnapshot(
  acquisition: {
    id: string;
    equipmentId: string;
    customerId: string;
    organizationId: string;
    serviceOrderId: string | null;
    source: AcquisitionSource;
    purpose: string;
    offeredAmount: Prisma.Decimal | null;
  },
  method: EquipmentConsentMethod,
  actorUserId: string,
  authorizedAt: Date
) {
  return {
    acquisitionId: acquisition.id,
    equipmentId: acquisition.equipmentId,
    customerId: acquisition.customerId,
    organizationId: acquisition.organizationId,
    serviceOrderId: acquisition.serviceOrderId,
    source: acquisition.source,
    purpose: acquisition.purpose,
    offeredAmountMinor: acquisition.offeredAmount === null
      ? null
      : decimalToMinorUnits(acquisition.offeredAmount, DECIMAL_10_2_MAX_MINOR),
    currency: 'BRL',
    consentMethod: method,
    authorizedByUserId: actorUserId,
    authorizedAt: authorizedAt.toISOString(),
  };
}

export class EquipmentAcquisitionService {
  async createProposal(
    principal: ValidatedPrincipal,
    operationId: string,
    input: CreateEquipmentAcquisitionInput
  ): Promise<AcquisitionCommandResult> {
    const organizationId = principal.organizationId ?? '';
    await resolveLiveAuthority(principal);
    assertStaff(principal, organizationId);
    return this.create(principal, operationId, organizationId, input, '/api/v1/equipment-acquisitions');
  }

  async createDirectOffer(
    principal: ValidatedPrincipal,
    operationId: string,
    input: CreateDirectOfferInput
  ): Promise<AcquisitionCommandResult> {
    const organizationId = principal.organizationId ?? '';
    await resolveLiveAuthority(principal);
    assertStaff(principal, organizationId);
    return this.create(principal, operationId, organizationId, input, '/api/v1/equipment-acquisitions/direct-offer');
  }

  private async create(
    principal: ValidatedPrincipal,
    operationId: string,
    organizationId: string,
    input: CreateInput,
    endpoint: string
  ): Promise<AcquisitionCommandResult> {
    const source = input.source;
    const serviceOrderId = source === AcquisitionSource.SERVICE_ORDER
      ? input.serviceOrderId
      : null;
    const identity: CommandIdentity = {
      operationId,
      organizationId,
      actorUserId: principal.sub,
      command: source === AcquisitionSource.SERVICE_ORDER
        ? 'P08B_CREATE_SERVICE_ORDER_ACQUISITION'
        : 'P08B_CREATE_DIRECT_OFFER',
      endpoint,
      requestHash: computeCanonicalHash({
        equipmentId: input.equipmentId,
        source,
        serviceOrderId,
        purpose: input.purpose,
        offeredAmountMinor: input.offeredAmountMinor ?? null,
        notes: input.notes ?? null,
        clientPreAcquisitionId: input.clientPreAcquisitionId ?? null,
      }),
    };
    const reservation = await reserve(identity);
    if (reservation.kind === 'REPLAY') return reservation.result;

    return prisma.$transaction(async tx => {
      await resolveLiveAuthority(principal, tx);
      await tx.$queryRaw(Prisma.sql`
        SELECT id FROM organizations WHERE id = ${organizationId} FOR UPDATE
      `);
      await tx.$queryRaw(Prisma.sql`
        SELECT id FROM equipments WHERE id = ${input.equipmentId} FOR UPDATE
      `);

      const fail = (statusCode: number, error: string) =>
        completeIdempotency(tx, identity, reservation.leaseToken, statusCode, { error });

      if (input.clientPreAcquisitionId) {
        const correlated = await tx.equipmentAcquisition.findUnique({
          where: {
            organizationId_clientPreAcquisitionId: {
              organizationId,
              clientPreAcquisitionId: input.clientPreAcquisitionId,
            },
          },
          include: acquisitionInclude,
        });
        if (correlated) {
          if (correlated.equipmentId !== input.equipmentId || correlated.source !== source) {
            return fail(409, 'CLIENT_PRE_ACQUISITION_INTENT_CONFLICT');
          }
          return completeIdempotency(
            tx,
            identity,
            reservation.leaseToken,
            200,
            jsonValue({ acquisition: acquisitionResponse(correlated) })
          );
        }
      }

      const equipment = await tx.equipment.findFirst({
        where: {
          id: input.equipmentId,
          ownerType: EquipmentOwnerType.CUSTOMER,
          customerId: { not: null },
        },
        select: { id: true, customerId: true },
      });
      if (!equipment?.customerId) return fail(404, 'EQUIPMENT_NOT_AVAILABLE');

      const relationship = await tx.customerOrganization.findFirst({
        where: {
          customerId: equipment.customerId,
          organizationId,
          status: 'ACTIVE',
        },
        select: { id: true },
      });
      if (!relationship) return fail(404, 'ACTIVE_CUSTOMER_RELATIONSHIP_NOT_FOUND');

      if (source === AcquisitionSource.SERVICE_ORDER) {
        const order = await tx.serviceOrder.findFirst({
          where: {
            id: serviceOrderId!,
            organizationId,
            customerId: equipment.customerId,
            equipmentId: equipment.id,
          },
          select: { id: true },
        });
        if (!order) return fail(404, 'SERVICE_ORDER_NOT_AVAILABLE');
      } else if (serviceOrderId !== null) {
        return fail(409, 'DIRECT_OFFER_SERVICE_ORDER_FORBIDDEN');
      }

      const active = await tx.equipmentAcquisition.findFirst({
        where: {
          equipmentId: equipment.id,
          status: { in: [EquipmentAcquisitionStatus.PENDING, EquipmentAcquisitionStatus.AUTHORIZED] },
        },
        select: { id: true },
      });
      if (active) return fail(409, 'EQUIPMENT_ACTIVE_ACQUISITION_EXISTS');

      const acquisition = await tx.equipmentAcquisition.create({
        data: {
          equipmentId: equipment.id,
          customerId: equipment.customerId,
          organizationId,
          serviceOrderId,
          source,
          clientPreAcquisitionId: input.clientPreAcquisitionId,
          purpose: input.purpose,
          offeredAmount: input.offeredAmountMinor === undefined
            ? null
            : minorUnitsToDecimal(input.offeredAmountMinor, DECIMAL_10_2_MAX_MINOR),
          notes: input.notes,
          status: EquipmentAcquisitionStatus.PENDING,
          createdByUserId: principal.sub,
        },
        include: acquisitionInclude,
      });
      await appendAudit(tx, acquisition, 'CREATE', principal.sub);
      return completeIdempotency(
        tx,
        identity,
        reservation.leaseToken,
        201,
        jsonValue({ acquisition: acquisitionResponse(acquisition) })
      );
    }, { isolationLevel: Prisma.TransactionIsolationLevel.ReadCommitted });
  }

  async listForOrganization(organizationId: string) {
    const acquisitions = await prisma.equipmentAcquisition.findMany({
      where: { organizationId },
      include: acquisitionInclude,
      orderBy: { createdAt: 'desc' },
    });
    return acquisitions.map(acquisitionResponse);
  }

  async listForCustomer(customerId: string) {
    const acquisitions = await prisma.equipmentAcquisition.findMany({
      where: { customerId },
      include: acquisitionInclude,
      orderBy: { createdAt: 'desc' },
    });
    return acquisitions.map(acquisitionResponse);
  }

  async findForOrganization(id: string, organizationId: string) {
    const acquisition = await prisma.equipmentAcquisition.findFirst({
      where: { id, organizationId },
      include: acquisitionInclude,
    });
    if (!acquisition) throw new NotFoundError('Equipment acquisition not found');
    return acquisitionResponse(acquisition);
  }

  async findForCustomer(id: string, customerId: string) {
    const acquisition = await prisma.equipmentAcquisition.findFirst({
      where: { id, customerId },
      include: acquisitionInclude,
    });
    if (!acquisition) throw new NotFoundError('Equipment acquisition not found');
    return acquisitionResponse(acquisition);
  }

  async authorize(
    principal: ValidatedPrincipal,
    operationId: string,
    id: string,
    input: AuthorizeEquipmentAcquisitionInput
  ): Promise<AcquisitionCommandResult> {
    await resolveLiveAuthority(principal);
    const customerId = principal.customerId ?? '';
    assertCustomer(principal, customerId);
    const scoped = await prisma.equipmentAcquisition.findFirst({
      where: { id, customerId },
      select: { organizationId: true },
    });
    if (!scoped) throw new NotFoundError('Equipment acquisition not found');
    return this.authorizeCommand(
      principal,
      operationId,
      id,
      scoped.organizationId,
      input.consentMethod,
      false
    );
  }

  async authorizeInPerson(
    principal: ValidatedPrincipal,
    operationId: string,
    id: string,
    input: AuthorizeInPersonInput
  ): Promise<AcquisitionCommandResult> {
    await resolveLiveAuthority(principal);
    const organizationId = principal.organizationId ?? '';
    assertStaff(principal, organizationId);
    return this.authorizeCommand(
      principal,
      operationId,
      id,
      organizationId,
      input.consentMethod,
      true
    );
  }

  private async authorizeCommand(
    principal: ValidatedPrincipal,
    operationId: string,
    id: string,
    organizationId: string,
    consentMethod: EquipmentConsentMethod,
    inPerson: boolean
  ): Promise<AcquisitionCommandResult> {
    const identity: CommandIdentity = {
      operationId,
      organizationId,
      actorUserId: principal.sub,
      command: inPerson ? 'P08B_AUTHORIZE_IN_PERSON' : 'P08B_CUSTOMER_AUTHORIZE',
      endpoint: `/api/v1/equipment-acquisitions/${id}/${inPerson ? 'authorize-in-person' : 'authorize'}`,
      requestHash: computeCanonicalHash({ id, consentMethod }),
    };
    const reservation = await reserve(identity);
    if (reservation.kind === 'REPLAY') return reservation.result;

    return prisma.$transaction(async tx => {
      await resolveLiveAuthority(principal, tx);
      await tx.$queryRaw(Prisma.sql`
        SELECT id FROM equipment_acquisitions WHERE id = ${id} FOR UPDATE
      `);
      const fail = (statusCode: number, error: string) =>
        completeIdempotency(tx, identity, reservation.leaseToken, statusCode, { error });
      const acquisition = await tx.equipmentAcquisition.findFirst({
        where: inPerson
          ? { id, organizationId }
          : { id, organizationId, customerId: principal.customerId! },
      });
      if (!acquisition) return fail(404, 'EQUIPMENT_ACQUISITION_NOT_FOUND');
      if (acquisition.status !== EquipmentAcquisitionStatus.PENDING) {
        return fail(409, 'ACQUISITION_NOT_PENDING');
      }
      if (inPerson && acquisition.source !== AcquisitionSource.DIRECT_OFFER) {
        return fail(409, 'IN_PERSON_REQUIRES_DIRECT_OFFER');
      }
      if (!inPerson && consentMethod === EquipmentConsentMethod.IN_PERSON_ASSISTED) {
        return fail(409, 'IN_PERSON_CONSENT_FORBIDDEN');
      }

      const authorizedAt = new Date();
      const snapshot = consentSnapshot(acquisition, consentMethod, principal.sub, authorizedAt);
      const updated = await tx.equipmentAcquisition.update({
        where: { id: acquisition.id },
        data: {
          status: EquipmentAcquisitionStatus.AUTHORIZED,
          consentMethod,
          consentSnapshot: snapshot,
          consentHash: computeCanonicalHash(snapshot),
          authorizedAt,
          authorizedByUserId: principal.sub,
        },
        include: acquisitionInclude,
      });
      await appendAudit(tx, updated, 'AUTHORIZE', principal.sub);
      return completeIdempotency(
        tx,
        identity,
        reservation.leaseToken,
        200,
        jsonValue({ acquisition: acquisitionResponse(updated) })
      );
    }, { isolationLevel: Prisma.TransactionIsolationLevel.ReadCommitted });
  }

  async reject(
    principal: ValidatedPrincipal,
    operationId: string,
    id: string
  ): Promise<AcquisitionCommandResult> {
    await resolveLiveAuthority(principal);
    const customerId = principal.customerId ?? '';
    assertCustomer(principal, customerId);
    const scoped = await prisma.equipmentAcquisition.findFirst({
      where: { id, customerId },
      select: { organizationId: true },
    });
    if (!scoped) throw new NotFoundError('Equipment acquisition not found');
    const identity: CommandIdentity = {
      operationId,
      organizationId: scoped.organizationId,
      actorUserId: principal.sub,
      command: 'P08B_CUSTOMER_REJECT',
      endpoint: `/api/v1/equipment-acquisitions/${id}/reject`,
      requestHash: computeCanonicalHash({ id }),
    };
    const reservation = await reserve(identity);
    if (reservation.kind === 'REPLAY') return reservation.result;

    return prisma.$transaction(async tx => {
      await resolveLiveAuthority(principal, tx);
      await tx.$queryRaw(Prisma.sql`
        SELECT id FROM equipment_acquisitions WHERE id = ${id} FOR UPDATE
      `);
      const fail = (statusCode: number, error: string) =>
        completeIdempotency(tx, identity, reservation.leaseToken, statusCode, { error });
      const acquisition = await tx.equipmentAcquisition.findFirst({
        where: { id, customerId, organizationId: scoped.organizationId },
      });
      if (!acquisition) return fail(404, 'EQUIPMENT_ACQUISITION_NOT_FOUND');
      if (acquisition.status !== EquipmentAcquisitionStatus.PENDING) {
        return fail(409, 'ACQUISITION_NOT_PENDING');
      }
      const updated = await tx.equipmentAcquisition.update({
        where: { id: acquisition.id },
        data: { status: EquipmentAcquisitionStatus.REJECTED, rejectedAt: new Date() },
        include: acquisitionInclude,
      });
      await appendAudit(tx, updated, 'REJECT', principal.sub);
      return completeIdempotency(
        tx,
        identity,
        reservation.leaseToken,
        200,
        jsonValue({ acquisition: acquisitionResponse(updated) })
      );
    }, { isolationLevel: Prisma.TransactionIsolationLevel.ReadCommitted });
  }

  async complete(
    principal: ValidatedPrincipal,
    operationId: string,
    id: string
  ): Promise<AcquisitionCommandResult> {
    await resolveLiveAuthority(principal);
    const organizationId = principal.organizationId ?? '';
    assertStaff(principal, organizationId);
    const identity: CommandIdentity = {
      operationId,
      organizationId,
      actorUserId: principal.sub,
      command: 'P08B_COMPLETE_ACQUISITION',
      endpoint: `/api/v1/equipment-acquisitions/${id}/complete`,
      requestHash: computeCanonicalHash({ id }),
    };
    const reservation = await reserve(identity);
    if (reservation.kind === 'REPLAY') return reservation.result;

    return syncTransaction(async tx => {
      await resolveLiveAuthority(principal, tx);
      await tx.$queryRaw(Prisma.sql`
        SELECT id FROM equipment_acquisitions WHERE id = ${id} FOR UPDATE
      `);
      const fail = (statusCode: number, error: string) =>
        completeIdempotency(tx, identity, reservation.leaseToken, statusCode, { error });
      const acquisition = await tx.equipmentAcquisition.findFirst({
        where: { id, organizationId },
      });
      if (!acquisition) return fail(404, 'EQUIPMENT_ACQUISITION_NOT_FOUND');
      if (acquisition.status !== EquipmentAcquisitionStatus.AUTHORIZED) {
        return fail(409, 'ACQUISITION_NOT_AUTHORIZED');
      }
      if (!acquisition.authorizedAt || !acquisition.authorizedByUserId ||
          !acquisition.consentMethod || !acquisition.consentSnapshot || !acquisition.consentHash) {
        return fail(409, 'ACQUISITION_CONSENT_INVALID');
      }
      if (
        acquisition.consentMethod === EquipmentConsentMethod.IN_PERSON_ASSISTED &&
        acquisition.source !== AcquisitionSource.DIRECT_OFFER
      ) {
        return fail(409, 'IN_PERSON_REQUIRES_DIRECT_OFFER');
      }

      await tx.$queryRaw(Prisma.sql`
        SELECT id FROM equipments WHERE id = ${acquisition.equipmentId} FOR UPDATE
      `);
      const transferred = await tx.equipment.updateMany({
        where: {
          id: acquisition.equipmentId,
          ownerType: EquipmentOwnerType.CUSTOMER,
          customerId: acquisition.customerId,
        },
        data: {
          ownerType: EquipmentOwnerType.ORGANIZATION,
          customerId: null,
          organizationId,
          organizationPurpose: acquisition.purpose,
        },
      });
      if (transferred.count !== 1) return fail(409, 'EQUIPMENT_OWNERSHIP_CONFLICT');

      const updated = await tx.equipmentAcquisition.update({
        where: { id: acquisition.id },
        data: {
          status: EquipmentAcquisitionStatus.COMPLETED,
          completedAt: new Date(),
          completedByUserId: principal.sub,
        },
        include: acquisitionInclude,
      });
      await appendAudit(tx, updated, 'COMPLETE', principal.sub);
      return completeIdempotency(
        tx,
        identity,
        reservation.leaseToken,
        200,
        jsonValue({ acquisition: acquisitionResponse(updated) })
      );
    });
  }
}
