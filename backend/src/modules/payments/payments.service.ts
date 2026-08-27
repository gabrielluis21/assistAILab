import {
  OperationType,
  PaymentStatus,
  Prisma,
} from '@prisma/client';

import { randomUUID } from 'node:crypto';

import { prisma } from '../../core/database/prisma.js';

import {
  computeCanonicalHash,
} from '../../core/idempotency/canonical_json.js';

import {
  IdempotencyService,
} from '../../core/idempotency/idempotency.service.js';

import {
  ConflictError,
  NotFoundError,
} from '../../core/utils/errors.js';

import type {
  CreatePaymentInput,
  PaymentListQuery,
  UpdatePaymentStatusInput,
} from './payments.schema.js';

const paymentInclude = {
  customer: {
    select: {
      id: true,
      name: true,
    },
  },
} satisfies Prisma.PaymentInclude;

type PaymentWithCustomer =
  Prisma.PaymentGetPayload<{
    include: typeof paymentInclude;
  }>;

export type PaymentCommandResult = {
  statusCode: number;
  body: Prisma.InputJsonValue;
};

function decimalToMinor(
  value: Prisma.Decimal
): number {
  const minor =
    value.mul(100).toNumber();

  if (!Number.isSafeInteger(minor)) {
    throw new Error(
      'Persisted Payment amount cannot be represented as a safe minor-unit integer'
    );
  }

  return minor;
}

function minorToDecimal(
  amountMinor: number
): Prisma.Decimal {
  return new Prisma.Decimal(
    amountMinor
  ).div(100);
}

export function serializePayment(
  payment: PaymentWithCustomer
) {
  return {
    id: payment.id,
    organizationId:
      payment.organizationId,
    serviceOrderId:
      payment.serviceOrderId,
    customerId:
      payment.customerId,
    amountMinor:
      decimalToMinor(
        payment.amount
      ),
    method:
      payment.method,
    status:
      payment.status,
    notes:
      payment.notes,
    paidAt:
      payment.paidAt
        ?.toISOString() ??
      null,
    cancelledAt:
      payment.cancelledAt
        ?.toISOString() ??
      null,
    version:
      payment.version,
    createdByUserId:
      payment.createdByUserId,
    confirmedByUserId:
      payment.confirmedByUserId,
    cancelledByUserId:
      payment.cancelledByUserId,
    createdAt:
      payment.createdAt
        .toISOString(),
    updatedAt:
      payment.updatedAt
        .toISOString(),
    customer:
      payment.customer,
  };
}

async function recordPaymentSyncChange(
  tx: Prisma.TransactionClient,
  payment:
    PaymentWithCustomer,
  operationType:
    OperationType
): Promise<void> {
  const change =
    await tx.syncChangeLog
      .create({
        data: {
          cursor:
            randomUUID(),
          entityType:
            'PAYMENT',
          entityId:
            payment.id,
          operationType,
          data:
            serializePayment(
              payment
            ) as Prisma.InputJsonValue,
        },
      });

  await tx.syncChangeLog
    .update({
      where: {
        id:
          change.id,
      },
      data: {
        cursor:
          change.id.toString(),
      },
    });
}

function replayResult(
  responseStatus: number,
  responseBody:
    Prisma.JsonValue
): PaymentCommandResult {
  return {
    statusCode:
      responseStatus,
    body:
      responseBody as
      Prisma.InputJsonValue,
  };
}

function handleReservationState(
  result:
    Awaited<
      ReturnType<
        IdempotencyService[
          'reserveOrReplay'
        ]
      >
    >
): PaymentCommandResult | null {
  if (
    result.kind ===
    'REPLAY'
  ) {
    return replayResult(
      result.responseStatus,
      result.responseBody
    );
  }

  if (
    result.kind ===
    'KEY_REUSE'
  ) {
    throw new ConflictError(
      'IDEMPOTENCY_KEY_REUSE'
    );
  }

  if (
    result.kind ===
    'IN_PROGRESS'
  ) {
    throw new ConflictError(
      'IDEMPOTENCY_IN_PROGRESS'
    );
  }

  return null;
}

export class PaymentsService {
  async listAll(
    organizationId: string,
    query:
      PaymentListQuery
  ) {
    const payments =
      await prisma.payment
        .findMany({
          where: {
            organizationId,
            ...(query.serviceOrderId
              ? {
                serviceOrderId:
                  query.serviceOrderId,
              }
              : {}),
            ...(query.customerId
              ? {
                customerId:
                  query.customerId,
              }
              : {}),
          },
          orderBy: {
            createdAt:
              'desc',
          },
          include:
            paymentInclude,
        });

    return payments.map(
      serializePayment
    );
  }

  async findById(
    organizationId: string,
    id: string
  ) {
    const payment =
      await prisma.payment
        .findFirst({
          where: {
            id,
            organizationId,
          },
          include:
            paymentInclude,
        });

    if (!payment) {
      throw new NotFoundError(
        `Payment ${id} not found`
      );
    }

    return serializePayment(
      payment
    );
  }

  async create(
    organizationId: string,
    actorUserId: string,
    operationId: string,
    data:
      CreatePaymentInput
  ): Promise<
    PaymentCommandResult
  > {
    /**
     * Tenant / authority validation occurs
     * BEFORE idempotency reservation.
     *
     * ServiceOrder is the authority for
     * organizationId + customerId.
     */
    const serviceOrder =
      await prisma.serviceOrder
        .findFirst({
          where: {
            id:
              data.serviceOrderId,
            organizationId,
          },
          select: {
            id: true,
            organizationId:
              true,
            customerId:
              true,
          },
        });

    if (!serviceOrder) {
      throw new NotFoundError(
        `Service Order ${data.serviceOrderId} not found`
      );
    }

    const endpoint =
      '/api/v1/payments';

    const command =
      'PAYMENT_CREATE';

    const requestHash =
      computeCanonicalHash({
        serviceOrderId:
          data.serviceOrderId,
        amountMinor:
          data.amountMinor,
        method:
          data.method,
        notes:
          data.notes ??
          null,
      });

    const identity = {
      operationId,
      actorUserId,
      organizationId,
      command,
      endpoint,
      requestHash,
    };

    const idempotency =
      new IdempotencyService(
        prisma
      );

    const reservation =
      await idempotency
        .reserveOrReplay(
          identity
        );

    const replay =
      handleReservationState(
        reservation
      );

    if (replay) {
      return replay;
    }

    if (
      reservation.kind !==
      'ACQUIRED'
    ) {
      throw new Error(
        'Unexpected idempotency state'
      );
    }

    return prisma.$transaction(
      async (tx) => {
        const payment =
          await tx.payment
            .create({
              data: {
                serviceOrderId:
                  serviceOrder.id,
                organizationId:
                  serviceOrder.organizationId,
                customerId:
                  serviceOrder.customerId,
                clientOperationId:
                  operationId,
                amount:
                  minorToDecimal(
                    data.amountMinor
                  ),
                method:
                  data.method,
                status:
                  PaymentStatus.PENDING,
                notes:
                  data.notes ??
                  null,
                createdByUserId:
                  actorUserId,
              },
              include:
                paymentInclude,
            });

        const serialized =
          serializePayment(
            payment
          );

        const body = {
          payment:
            serialized,
        } as Prisma.InputJsonValue;

        await recordPaymentSyncChange(
          tx,
          payment,
          OperationType.CREATE
        );

        await IdempotencyService
          .completeWithinTransaction(
            tx,
            {
              ...identity,
              leaseToken:
                reservation
                  .leaseToken,
              responseStatus:
                201,
              responseBody:
                body,
            }
          );

        return {
          statusCode:
            201,
          body,
        };
      }
    );
  }

  async updateStatus(
    organizationId: string,
    actorUserId: string,
    operationId: string,
    id: string,
    data:
      UpdatePaymentStatusInput
  ): Promise<
    PaymentCommandResult
  > {
    /**
     * Existence / tenant authorization
     * happens before idempotency, but no
     * mutable-state validation does.
     */
    const tenantPayment =
      await prisma.payment
        .findFirst({
          where: {
            id,
            organizationId,
          },
          select: {
            id:
              true,
          },
        });

    if (!tenantPayment) {
      throw new NotFoundError(
        `Payment ${id} not found`
      );
    }

    const endpoint =
      `/api/v1/payments/${id}/status`;

    const command =
      data.status ===
      'CONFIRMED'
        ? 'PAYMENT_CONFIRM'
        : 'PAYMENT_CANCEL';

    const requestHash =
      computeCanonicalHash({
        paymentId:
          id,
        status:
          data.status,
      });

    const identity = {
      operationId,
      actorUserId,
      organizationId,
      command,
      endpoint,
      requestHash,
    };

    const idempotency =
      new IdempotencyService(
        prisma
      );

    const reservation =
      await idempotency
        .reserveOrReplay(
          identity
        );

    const replay =
      handleReservationState(
        reservation
      );

    if (replay) {
      return replay;
    }

    if (
      reservation.kind !==
      'ACQUIRED'
    ) {
      throw new Error(
        'Unexpected idempotency state'
      );
    }

    return prisma.$transaction(
      async (tx) => {
        /**
         * Mutable-state validation is
         * intentionally after ACQUIRED.
         */
        const current =
          await tx.payment
            .findFirst({
              where: {
                id,
                organizationId,
              },
              select: {
                status:
                  true,
                version:
                  true,
              },
            });

        if (!current) {
          const body = {
            error:
              'PAYMENT_NOT_FOUND',
          } as Prisma.InputJsonValue;

          await IdempotencyService
            .completeWithinTransaction(
              tx,
              {
                ...identity,
                leaseToken:
                  reservation
                    .leaseToken,
                responseStatus:
                  404,
                responseBody:
                  body,
              }
            );

          return {
            statusCode:
              404,
            body,
          };
        }

        if (
          current.status !==
          PaymentStatus.PENDING
        ) {
          const body = {
            error:
              'PAYMENT_STATUS_CONFLICT',
            message:
              `Cannot transition Payment from ${current.status} to ${data.status}`,
          } as Prisma.InputJsonValue;

          await IdempotencyService
            .completeWithinTransaction(
              tx,
              {
                ...identity,
                leaseToken:
                  reservation
                    .leaseToken,
                responseStatus:
                  409,
                responseBody:
                  body,
              }
            );

          return {
            statusCode:
              409,
            body,
          };
        }

        const now =
          new Date();

        const mutation =
          data.status ===
          'CONFIRMED'
            ? {
              status:
                PaymentStatus
                  .CONFIRMED,
              paidAt:
                now,
              confirmedByUserId:
                actorUserId,
              cancelledAt:
                null,
              cancelledByUserId:
                null,
              version: {
                increment:
                  1,
              },
            }
            : {
              status:
                PaymentStatus
                  .CANCELLED,
              paidAt:
                null,
              cancelledAt:
                now,
              cancelledByUserId:
                actorUserId,
              confirmedByUserId:
                null,
              version: {
                increment:
                  1,
              },
            };

        /**
         * Status + version CAS.
         */
        const updated =
          await tx.payment
            .updateMany({
              where: {
                id,
                organizationId,
                status:
                  PaymentStatus
                    .PENDING,
                version:
                  current.version,
              },
              data:
                mutation,
            });

        if (
          updated.count !==
          1
        ) {
          const body = {
            error:
              'PAYMENT_STATUS_CONFLICT',
            message:
              'Payment status changed concurrently',
          } as Prisma.InputJsonValue;

          await IdempotencyService
            .completeWithinTransaction(
              tx,
              {
                ...identity,
                leaseToken:
                  reservation
                    .leaseToken,
                responseStatus:
                  409,
                responseBody:
                  body,
              }
            );

          return {
            statusCode:
              409,
            body,
          };
        }

        const payment =
          await tx.payment
            .findFirstOrThrow({
              where: {
                id,
                organizationId,
              },
              include:
                paymentInclude,
            });

        const serialized =
          serializePayment(
            payment
          );

        const body = {
          payment:
            serialized,
        } as Prisma.InputJsonValue;

        await recordPaymentSyncChange(
          tx,
          payment,
          OperationType.UPDATE
        );

        await IdempotencyService
          .completeWithinTransaction(
            tx,
            {
              ...identity,
              leaseToken:
                reservation
                  .leaseToken,
              responseStatus:
                200,
              responseBody:
                body,
            }
          );

        return {
          statusCode:
            200,
          body,
        };
      }
    );
  }

  async getRevenueSummary(
    organizationId: string
  ) {
    const now =
      new Date();

    const startOfMonth =
      new Date(
        now.getFullYear(),
        now.getMonth(),
        1
      );

    const [
      totalRevenue,
      monthRevenue,
      pending,
    ] =
      await Promise.all([
        prisma.payment
          .aggregate({
            where: {
              organizationId,
              status:
                PaymentStatus
                  .CONFIRMED,
            },
            _sum: {
              amount:
                true,
            },
          }),

        prisma.payment
          .aggregate({
            where: {
              organizationId,
              status:
                PaymentStatus
                  .CONFIRMED,
              paidAt: {
                gte:
                  startOfMonth,
              },
            },
            _sum: {
              amount:
                true,
            },
          }),

        prisma.payment
          .aggregate({
            where: {
              organizationId,
              status:
                PaymentStatus
                  .PENDING,
            },
            _sum: {
              amount:
                true,
            },
            _count:
              true,
          }),
      ]);

    const zero =
      new Prisma.Decimal(0);

    return {
      totalRevenueMinor:
        decimalToMinor(
          totalRevenue
            ._sum.amount ??
          zero
        ),
      monthRevenueMinor:
        decimalToMinor(
          monthRevenue
            ._sum.amount ??
          zero
        ),
      pendingAmountMinor:
        decimalToMinor(
          pending
            ._sum.amount ??
          zero
        ),
      pendingCount:
        pending._count,
    };
  }
}
