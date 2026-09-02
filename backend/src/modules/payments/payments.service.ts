import {
  FinancialAuditOrigin,
  OperationType,
  PaymentStatus,
  Prisma,
  ReceivableLifecycleStatus,
} from '@prisma/client';

import {
  randomUUID,
} from 'node:crypto';

import {
  prisma,
} from '../../core/database/prisma.js';

import {
  computeCanonicalHash,
} from '../../core/idempotency/canonical_json.js';

import {
  IdempotencyService,
} from '../../core/idempotency/idempotency.service.js';

import {
  decimalToMinorUnits,
  minorUnitsToDecimal,
} from '../../core/money/money.js';

import {
  ConflictError,
  NotFoundError,
} from '../../core/utils/errors.js';

import {
  buildCurrentScheduleAllocationPlan,
  decimalMinor,
  deriveReceivableFinancialStatus,
} from './payments.fin-f02.rules.js';

import type {
  CreatePaymentInput,
  PaymentListQuery,
  UpdatePaymentStatusInput,
} from './payments.schema.js';

const paymentInclude = {
  customer: {
    select: {
      id:
        true,
      name:
        true,
    },
  },
} satisfies Prisma.PaymentInclude;

type PaymentWithCustomer =
  Prisma.PaymentGetPayload<{
    include:
      typeof paymentInclude;
  }>;

type IdempotencyIdentity = {
  operationId:
    string;

  actorUserId:
    string;

  organizationId:
    string;

  command:
    string;

  endpoint:
    string;

  requestHash:
    string;
};

export type PaymentCommandResult = {
  statusCode:
    number;

  body:
    Prisma.InputJsonValue;
};

export function serializePayment(
  payment:
    PaymentWithCustomer
) {
  return {
    id:
      payment.id,

    organizationId:
      payment.organizationId,

    serviceOrderId:
      payment.serviceOrderId,

    customerId:
      payment.customerId,

    amountMinor:
      decimalToMinorUnits(
        payment.amount
      ),

    method:
      payment.method,

    status:
      payment.status,

    cardInstallmentCount:
      payment
        .cardInstallmentCount,

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
      payment
        .createdByUserId,

    confirmedByUserId:
      payment
        .confirmedByUserId,

    cancelledByUserId:
      payment
        .cancelledByUserId,

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
  tx:
    Prisma.TransactionClient,
  payment:
    PaymentWithCustomer,
  operationType:
    OperationType
): Promise<void> {
  const change =
    await tx
      .syncChangeLog
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
            ) as
              Prisma.InputJsonValue,
        },
      });

  await tx
    .syncChangeLog
    .update({
      where: {
        id:
          change.id,
      },

      data: {
        cursor:
          change.id
            .toString(),
      },
    });
}

function replayResult(
  responseStatus:
    number,
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

async function completeCommand(
  tx:
    Prisma.TransactionClient,
  identity:
    IdempotencyIdentity,
  leaseToken:
    string,
  statusCode:
    number,
  body:
    Prisma.InputJsonValue
): Promise<PaymentCommandResult> {
  await IdempotencyService
    .completeWithinTransaction(
      tx,
      {
        ...identity,

        leaseToken,

        responseStatus:
          statusCode,

        responseBody:
          body,
      }
    );

  return {
    statusCode,
    body,
  };
}

async function lockServiceOrder(
  tx:
    Prisma.TransactionClient,
  serviceOrderId:
    string,
  organizationId:
    string
) {
  const locked =
    await tx
      .$queryRaw<
        Array<{
          id:
            string;
        }>
      >(
        Prisma.sql`
          SELECT id
          FROM service_orders
          WHERE id =
            ${serviceOrderId}
            AND organizationId =
            ${organizationId}
          FOR UPDATE
        `
      );

  if (
    locked.length !==
    1
  ) {
    return null;
  }

  return tx
    .serviceOrder
    .findFirst({
      where: {
        id:
          serviceOrderId,

        organizationId,
      },

      select: {
        id:
          true,

        organizationId:
          true,

        customerId:
          true,

        financeCoreVersion:
          true,
      },
    });
}

async function lockActiveReceivable(
  tx:
    Prisma.TransactionClient,
  serviceOrderId:
    string,
  organizationId:
    string
) {
  const rows =
    await tx
      .$queryRaw<
        Array<{
          id:
            string;

          lifecycleStatus:
            ReceivableLifecycleStatus;

          totalAmount:
            Prisma.Decimal;

          currentScheduleVersion:
            number;
        }>
      >(
        Prisma.sql`
          SELECT
            id,
            lifecycleStatus,
            totalAmount,
            currentScheduleVersion
          FROM receivables
          WHERE serviceOrderId =
            ${serviceOrderId}
            AND organizationId =
            ${organizationId}
          ORDER BY id
          FOR UPDATE
        `
      );

  const active =
    rows.filter(
      (
        row
      ) =>
        row.lifecycleStatus ===
        ReceivableLifecycleStatus
          .ACTIVE
    );

  return active.length ===
    1
    ? active[0]
    : null;
}

export class PaymentsService {
  async listAll(
    organizationId:
      string,
    query:
      PaymentListQuery
  ) {
    const payments =
      await prisma
        .payment
        .findMany({
          where: {
            organizationId,

            ...(
              query.serviceOrderId
                ? {
                    serviceOrderId:
                      query
                        .serviceOrderId,
                  }
                : {}
            ),

            ...(
              query.customerId
                ? {
                    customerId:
                      query.customerId,
                  }
                : {}
            ),
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
    organizationId:
      string,
    id:
      string
  ) {
    const payment =
      await prisma
        .payment
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
    organizationId:
      string,
    actorUserId:
      string,
    operationId:
      string,
    data:
      CreatePaymentInput
  ): Promise<
    PaymentCommandResult
  > {
    /**
     * FIN-F01 tenant / authority validation remains before H02.
     * ServiceOrder remains authoritative for organization/customer.
     */
    const preflightOrder =
      await prisma
        .serviceOrder
        .findFirst({
          where: {
            id:
              data
                .serviceOrderId,

            organizationId,
          },

          select: {
            id:
              true,
          },
        });

    if (
      !preflightOrder
    ) {
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

        cardInstallmentCount:
          data
            .cardInstallmentCount ??
          null,

        notes:
          data.notes ??
          null,
      });

    const identity:
      IdempotencyIdentity = {
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

    return prisma
      .$transaction(
        async (
          tx
        ) => {
          /**
           * Frozen lock root:
           * H02 -> ServiceOrder.
           *
           * This additional lock also revalidates tenant authority after
           * idempotency without changing the legacy Payment response.
           */
          const serviceOrder =
            await lockServiceOrder(
              tx,
              data
                .serviceOrderId,
              organizationId
            );

          if (
            !serviceOrder
          ) {
            return completeCommand(
              tx,
              identity,
              reservation
                .leaseToken,
              404,
              {
                error:
                  'SERVICE_ORDER_NOT_FOUND',
              } as
                Prisma.InputJsonValue
            );
          }

          let v2ReceivableId:
            string |
            null =
              null;

          if (
            serviceOrder
              .financeCoreVersion ===
            2
          ) {
            const activeReceivable =
              await lockActiveReceivable(
                tx,
                serviceOrder.id,
                organizationId
              );

            if (
              !activeReceivable
            ) {
              return completeCommand(
                tx,
                identity,
                reservation
                  .leaseToken,
                409,
                {
                  error:
                    'FIN_F02_ACTIVE_RECEIVABLE_REQUIRED',
                } as
                  Prisma.InputJsonValue
              );
            }

            if (
              data.amountMinor >
              decimalMinor(
                activeReceivable
                  .totalAmount
              )
            ) {
              return completeCommand(
                tx,
                identity,
                reservation
                  .leaseToken,
                409,
                {
                  error:
                    'PAYMENT_AMOUNT_EXCEEDS_RECEIVABLE_TOTAL',
                } as
                  Prisma.InputJsonValue
              );
            }

            v2ReceivableId =
              activeReceivable.id;
          }

          const payment =
            await tx
              .payment
              .create({
                data: {
                  serviceOrderId:
                    serviceOrder.id,

                  organizationId:
                    serviceOrder
                      .organizationId,

                  customerId:
                    serviceOrder
                      .customerId,

                  clientOperationId:
                    operationId,

                  amount:
                    minorUnitsToDecimal(
                      data.amountMinor
                    ),

                  method:
                    data.method,

                  status:
                    PaymentStatus
                      .PENDING,

                  cardInstallmentCount:
                    data
                      .cardInstallmentCount ??
                    null,

                  notes:
                    data.notes ??
                    null,

                  createdByUserId:
                    actorUserId,
                },

                include:
                  paymentInclude,
              });

          if (
            v2ReceivableId
          ) {
            await tx
              .financialAuditEvent
              .create({
                data: {
                  organizationId:
                    serviceOrder
                      .organizationId,

                  serviceOrderId:
                    serviceOrder.id,

                  actorUserId,

                  origin:
                    FinancialAuditOrigin
                      .USER_COMMAND,

                  eventType:
                    'PAYMENT_PENDING_CREATED',

                  entityType:
                    'PAYMENT',

                  entityId:
                    payment.id,

                  operationId,

                  ordinal:
                    1,

                  metadata: {
                    receivableId:
                      v2ReceivableId,

                    amountMinor:
                      data.amountMinor,

                    method:
                      data.method,

                    cardInstallmentCount:
                      data
                        .cardInstallmentCount ??
                      null,
                  },
                },
              });
          }

          const serialized =
            serializePayment(
              payment
            );

          const body = {
            payment:
              serialized,
          } as
            Prisma.InputJsonValue;

          /**
           * FIN-F01 Payment Sync behavior is intentionally preserved in
           * this phase. FIN-F02 generic Sync Pull denial is a later
           * dedicated frozen gate.
           */
          await recordPaymentSyncChange(
            tx,
            payment,
            OperationType.CREATE
          );

          return completeCommand(
            tx,
            identity,
            reservation
              .leaseToken,
            201,
            body
          );
        }
      );
  }

  async updateStatus(
    organizationId:
      string,
    actorUserId:
      string,
    operationId:
      string,
    id:
      string,
    data:
      UpdatePaymentStatusInput
  ): Promise<
    PaymentCommandResult
  > {
    /**
     * FIN-F01 existence/tenant authorization remains before H02.
     * Mutable state is validated only after ACQUIRED.
     */
    const tenantPayment =
      await prisma
        .payment
        .findFirst({
          where: {
            id,
            organizationId,
          },

          select: {
            id:
              true,

            serviceOrderId:
              true,
          },
        });

    if (
      !tenantPayment
    ) {
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

    const identity:
      IdempotencyIdentity = {
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

    return prisma
      .$transaction(
        async (
          tx
        ) => {
          /**
           * FIN-F02 frozen lock root. Legacy orders also tolerate this
           * additional serialization without changing FIN-F01 semantics.
           */
          const serviceOrder =
            await lockServiceOrder(
              tx,
              tenantPayment
                .serviceOrderId,
              organizationId
            );

          if (
            !serviceOrder
          ) {
            return completeCommand(
              tx,
              identity,
              reservation
                .leaseToken,
              404,
              {
                error:
                  'PAYMENT_NOT_FOUND',
              } as
                Prisma.InputJsonValue
            );
          }

          if (
            serviceOrder
              .financeCoreVersion ===
              2 &&
            data.status ===
              'CONFIRMED'
          ) {
            return this
              .confirmFinanceCorePayment(
                tx,
                serviceOrder,
                actorUserId,
                id,
                operationId,
                identity,
                reservation
                  .leaseToken
              );
          }

          return this
            .transitionPendingPayment(
              tx,
              serviceOrder,
              actorUserId,
              id,
              operationId,
              data,
              identity,
              reservation
                .leaseToken
            );
        }
      );
  }

  private async confirmFinanceCorePayment(
    tx:
      Prisma.TransactionClient,
    serviceOrder: {
      id:
        string;

      organizationId:
        string;

      customerId:
        string;

      financeCoreVersion:
        number |
        null;
    },
    actorUserId:
      string,
    paymentId:
      string,
    operationId:
      string,
    identity:
      IdempotencyIdentity,
    leaseToken:
      string
  ): Promise<
    PaymentCommandResult
  > {
    /**
     * Frozen order after ServiceOrder:
     * Receivable -> current Schedule -> current Installments -> Payment
     * -> allocation aggregates.
     */
    const receivable =
      await lockActiveReceivable(
        tx,
        serviceOrder.id,
        serviceOrder
          .organizationId
      );

    if (
      !receivable
    ) {
      return completeCommand(
        tx,
        identity,
        leaseToken,
        409,
        {
          error:
            'FIN_F02_ACTIVE_RECEIVABLE_REQUIRED',
        } as
          Prisma.InputJsonValue
      );
    }

    const lockedSchedule =
      await tx
        .$queryRaw<
          Array<{
            id:
              string;

            version:
              number;
          }>
        >(
          Prisma.sql`
            SELECT
              id,
              version
            FROM receivable_schedules
            WHERE receivableId =
              ${receivable.id}
              AND version =
                ${receivable.currentScheduleVersion}
            ORDER BY id
            FOR UPDATE
          `
        );

    if (
      lockedSchedule.length !==
      1
    ) {
      return completeCommand(
        tx,
        identity,
        leaseToken,
        409,
        {
          error:
            'CURRENT_RECEIVABLE_SCHEDULE_INVALID',
        } as
          Prisma.InputJsonValue
      );
    }

    const schedule =
      lockedSchedule[0];

    const installments =
      await tx
        .$queryRaw<
          Array<{
            id:
              string;

            sequence:
              number;

            amount:
              Prisma.Decimal;
          }>
        >(
          Prisma.sql`
            SELECT
              id,
              sequence,
              amount
            FROM receivable_installments
            WHERE receivableId =
              ${receivable.id}
              AND scheduleId =
                ${schedule.id}
              AND scheduleVersion =
                ${schedule.version}
            ORDER BY
              sequence,
              id
            FOR UPDATE
          `
        );

    if (
      installments.length ===
      0
    ) {
      return completeCommand(
        tx,
        identity,
        leaseToken,
        409,
        {
          error:
            'CURRENT_RECEIVABLE_INSTALLMENTS_MISSING',
        } as
          Prisma.InputJsonValue
      );
    }

    const lockedPayment =
      await tx
        .$queryRaw<
          Array<{
            id:
              string;
          }>
        >(
          Prisma.sql`
            SELECT id
            FROM payments
            WHERE id =
              ${paymentId}
              AND organizationId =
                ${serviceOrder.organizationId}
            FOR UPDATE
          `
        );

    if (
      lockedPayment.length !==
      1
    ) {
      return completeCommand(
        tx,
        identity,
        leaseToken,
        404,
        {
          error:
            'PAYMENT_NOT_FOUND',
        } as
          Prisma.InputJsonValue
      );
    }

    const current =
      await tx
        .payment
        .findFirst({
          where: {
            id:
              paymentId,

            organizationId:
              serviceOrder
                .organizationId,
          },

          include:
            paymentInclude,
        });

    if (
      !current ||
      current.serviceOrderId !==
        serviceOrder.id ||
      current.customerId !==
        serviceOrder.customerId
    ) {
      return completeCommand(
        tx,
        identity,
        leaseToken,
        409,
        {
          error:
            'PAYMENT_RECEIVABLE_AUTHORITY_MISMATCH',
        } as
          Prisma.InputJsonValue
      );
    }

    if (
      current.status !==
      PaymentStatus.PENDING
    ) {
      return completeCommand(
        tx,
        identity,
        leaseToken,
        409,
        {
          error:
            'PAYMENT_STATUS_CONFLICT',

          message:
            `Cannot transition Payment from ${current.status} to CONFIRMED`,
        } as
          Prisma.InputJsonValue
      );
    }

    /**
     * Allocation rows are the financial truth for FIN-F02.
     * Aggregate only after Payment is locked.
     */
    const existingAllocations =
      await tx
        .paymentAllocation
        .findMany({
          where: {
            receivableId:
              receivable.id,
          },

          select: {
            installmentId:
              true,

            amount:
              true,
          },
        });

    const allocatedBeforeMinor =
      existingAllocations
        .reduce(
          (
            sum,
            allocation
          ) =>
            sum +
            decimalMinor(
              allocation.amount
            ),
          0
        );

    const paymentAmountMinor =
      decimalMinor(
        current.amount
      );

    const receivableTotalMinor =
      decimalMinor(
        receivable
          .totalAmount
      );

    if (
      allocatedBeforeMinor +
        paymentAmountMinor >
      receivableTotalMinor
    ) {
      return completeCommand(
        tx,
        identity,
        leaseToken,
        409,
        {
          error:
            'PAYMENT_EXCEEDS_RECEIVABLE_OUTSTANDING',

          receivableTotalMinor,

          allocatedBeforeMinor,

          candidatePaymentMinor:
            paymentAmountMinor,
        } as
          Prisma.InputJsonValue
      );
    }

    const allocatedByInstallment =
      new Map<
        string,
        number
      >();

    for (
      const allocation of
      existingAllocations
    ) {
      allocatedByInstallment
        .set(
          allocation
            .installmentId,
          (
            allocatedByInstallment
              .get(
                allocation
                  .installmentId
              ) ??
            0
          ) +
            decimalMinor(
              allocation
                .amount
            )
        );
    }

    let allocationPlan:
      ReturnType<
        typeof buildCurrentScheduleAllocationPlan
      >;

    try {
      allocationPlan =
        buildCurrentScheduleAllocationPlan(
          paymentAmountMinor,

          installments.map(
            (
              installment
            ) => ({
              id:
                installment.id,

              sequence:
                installment
                  .sequence,

              amountMinor:
                decimalMinor(
                  installment
                    .amount
                ),

              allocatedMinor:
                allocatedByInstallment
                  .get(
                    installment.id
                  ) ??
                0,
            })
          )
        );
    } catch {
      return completeCommand(
        tx,
        identity,
        leaseToken,
        409,
        {
          error:
            'CURRENT_SCHEDULE_CANNOT_ALLOCATE_PAYMENT',
        } as
          Prisma.InputJsonValue
      );
    }

    const now =
      new Date();

    const updated =
      await tx
        .payment
        .updateMany({
          where: {
            id:
              paymentId,

            organizationId:
              serviceOrder
                .organizationId,

            status:
              PaymentStatus
                .PENDING,

            version:
              current.version,
          },

          data: {
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
          },
        });

    if (
      updated.count !==
      1
    ) {
      return completeCommand(
        tx,
        identity,
        leaseToken,
        409,
        {
          error:
            'PAYMENT_STATUS_CONFLICT',

          message:
            'Payment status changed concurrently',
        } as
          Prisma.InputJsonValue
      );
    }

    const createdAllocations:
      Array<{
        id:
          string;

        installmentId:
          string;

        sequence:
          number;

        amountMinor:
          number;
      }> =
      [];

    for (
      const line of
      allocationPlan
    ) {
      const allocation =
        await tx
          .paymentAllocation
          .create({
            data: {
              organizationId:
                serviceOrder
                  .organizationId,

              customerId:
                serviceOrder
                  .customerId,

              serviceOrderId:
                serviceOrder.id,

              receivableId:
                receivable.id,

              installmentId:
                line
                  .installmentId,

              paymentId:
                current.id,

              amount:
                minorUnitsToDecimal(
                  line
                    .amountMinor
                ),

              createdByUserId:
                actorUserId,
            },
          });

      createdAllocations
        .push({
          id:
            allocation.id,

          installmentId:
            allocation
              .installmentId,

          sequence:
            line.sequence,

          amountMinor:
            line.amountMinor,
        });
    }

    const allocatedAfterMinor =
      allocatedBeforeMinor +
      paymentAmountMinor;

    const financialStatus =
      deriveReceivableFinancialStatus(
        receivableTotalMinor,
        allocatedAfterMinor
      );

    const auditRows:
      Prisma.FinancialAuditEventCreateManyInput[] =
      [
        {
          organizationId:
            serviceOrder
              .organizationId,

          serviceOrderId:
            serviceOrder.id,

          actorUserId,

          origin:
            FinancialAuditOrigin
              .USER_COMMAND,

          eventType:
            'PAYMENT_CONFIRMED',

          entityType:
            'PAYMENT',

          entityId:
            current.id,

          operationId,

          ordinal:
            1,

          occurredAt:
            now,

          metadata: {
            receivableId:
              receivable.id,

            amountMinor:
              paymentAmountMinor,

            allocatedBeforeMinor,

            allocatedAfterMinor,

            receivableTotalMinor,

            financialStatus,
          },
        },
      ];

    createdAllocations
      .forEach(
        (
          allocation,
          index
        ) => {
          auditRows.push({
            organizationId:
              serviceOrder
                .organizationId,

            serviceOrderId:
              serviceOrder.id,

            actorUserId:
              null,

            origin:
              FinancialAuditOrigin
                .SYSTEM_DERIVED,

            eventType:
              'PAYMENT_ALLOCATED',

            entityType:
              'PAYMENT_ALLOCATION',

            entityId:
              allocation.id,

            operationId,

            ordinal:
              index +
              2,

            occurredAt:
              now,

            metadata: {
              paymentId:
                current.id,

              receivableId:
                receivable.id,

              installmentId:
                allocation
                  .installmentId,

              installmentSequence:
                allocation
                  .sequence,

              amountMinor:
                allocation
                  .amountMinor,
            },
          });
        }
      );

    await tx
      .financialAuditEvent
      .createMany({
        data:
          auditRows,
      });

    const payment =
      await tx
        .payment
        .findFirstOrThrow({
          where: {
            id:
              current.id,

            organizationId:
              serviceOrder
                .organizationId,
          },

          include:
            paymentInclude,
        });

    const body = {
      payment:
        serializePayment(
          payment
        ),

      receivable: {
        id:
          receivable.id,

        totalAmountMinor:
          receivableTotalMinor,

        allocatedBeforeMinor,

        allocatedAfterMinor,

        outstandingAmountMinor:
          receivableTotalMinor -
          allocatedAfterMinor,

        financialStatus,

        currentScheduleVersion:
          receivable
            .currentScheduleVersion,
      },

      allocations:
        createdAllocations,
    } as
      Prisma.InputJsonValue;

    await recordPaymentSyncChange(
      tx,
      payment,
      OperationType.UPDATE
    );

    return completeCommand(
      tx,
      identity,
      leaseToken,
      200,
      body
    );
  }

  private async transitionPendingPayment(
    tx:
      Prisma.TransactionClient,
    serviceOrder: {
      id:
        string;

      organizationId:
        string;

      customerId:
        string;

      financeCoreVersion:
        number |
        null;
    },
    actorUserId:
      string,
    paymentId:
      string,
    operationId:
      string,
    data:
      UpdatePaymentStatusInput,
    identity:
      IdempotencyIdentity,
    leaseToken:
      string
  ): Promise<
    PaymentCommandResult
  > {
    /**
     * For FIN-F02 cancellation, serialize on Payment after ServiceOrder.
     * Legacy remains CAS-driven as in FIN-F01.
     */
    if (
      serviceOrder
        .financeCoreVersion ===
      2
    ) {
      const lockedPayment =
        await tx
          .$queryRaw<
            Array<{
              id:
                string;
            }>
          >(
            Prisma.sql`
              SELECT id
              FROM payments
              WHERE id =
                ${paymentId}
                AND organizationId =
                  ${serviceOrder.organizationId}
              FOR UPDATE
            `
          );

      if (
        lockedPayment.length !==
        1
      ) {
        return completeCommand(
          tx,
          identity,
          leaseToken,
          404,
          {
            error:
              'PAYMENT_NOT_FOUND',
          } as
            Prisma.InputJsonValue
        );
      }
    }

    const current =
      await tx
        .payment
        .findFirst({
          where: {
            id:
              paymentId,

            organizationId:
              serviceOrder
                .organizationId,
          },

          select: {
            serviceOrderId:
              true,

            customerId:
              true,

            status:
              true,

            version:
              true,
          },
        });

    if (
      !current
    ) {
      return completeCommand(
        tx,
        identity,
        leaseToken,
        404,
        {
          error:
            'PAYMENT_NOT_FOUND',
        } as
          Prisma.InputJsonValue
      );
    }

    if (
      current.serviceOrderId !==
        serviceOrder.id ||
      current.customerId !==
        serviceOrder.customerId
    ) {
      return completeCommand(
        tx,
        identity,
        leaseToken,
        409,
        {
          error:
            'PAYMENT_SERVICE_ORDER_AUTHORITY_MISMATCH',
        } as
          Prisma.InputJsonValue
      );
    }

    if (
      current.status !==
      PaymentStatus.PENDING
    ) {
      return completeCommand(
        tx,
        identity,
        leaseToken,
        409,
        {
          error:
            'PAYMENT_STATUS_CONFLICT',

          message:
            `Cannot transition Payment from ${current.status} to ${data.status}`,
        } as
          Prisma.InputJsonValue
      );
    }

    if (
      serviceOrder
        .financeCoreVersion ===
        2 &&
      data.status ===
        'CANCELLED'
    ) {
      const allocationCount =
        await tx
          .paymentAllocation
          .count({
            where: {
              paymentId,
            },
          });

      if (
        allocationCount !==
        0
      ) {
        return completeCommand(
          tx,
          identity,
          leaseToken,
          409,
          {
            error:
              'PENDING_PAYMENT_HAS_ALLOCATIONS',
          } as
            Prisma.InputJsonValue
        );
      }
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

    const updated =
      await tx
        .payment
        .updateMany({
          where: {
            id:
              paymentId,

            organizationId:
              serviceOrder
                .organizationId,

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
      return completeCommand(
        tx,
        identity,
        leaseToken,
        409,
        {
          error:
            'PAYMENT_STATUS_CONFLICT',

          message:
            'Payment status changed concurrently',
        } as
          Prisma.InputJsonValue
      );
    }

    const payment =
      await tx
        .payment
        .findFirstOrThrow({
          where: {
            id:
              paymentId,

            organizationId:
              serviceOrder
                .organizationId,
          },

          include:
            paymentInclude,
        });

    if (
      serviceOrder
        .financeCoreVersion ===
        2
    ) {
      await tx
        .financialAuditEvent
        .create({
          data: {
            organizationId:
              serviceOrder
                .organizationId,

            serviceOrderId:
              serviceOrder.id,

            actorUserId,

            origin:
              FinancialAuditOrigin
                .USER_COMMAND,

            eventType:
              data.status ===
              'CANCELLED'
                ? 'PAYMENT_CANCELLED'
                : 'PAYMENT_CONFIRMED',

            entityType:
              'PAYMENT',

            entityId:
              payment.id,

            operationId,

            ordinal:
              1,

            occurredAt:
              now,

            metadata: {
              amountMinor:
                decimalToMinorUnits(
                  payment.amount
                ),

              financeCoreVersion:
                2,
            },
          },
        });
    }

    const body = {
      payment:
        serializePayment(
          payment
        ),
    } as
      Prisma.InputJsonValue;

    await recordPaymentSyncChange(
      tx,
      payment,
      OperationType.UPDATE
    );

    return completeCommand(
      tx,
      identity,
      leaseToken,
      200,
      body
    );
  }

  async getRevenueSummary(
    organizationId:
      string
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
      new Prisma.Decimal(
        0
      );

    return {
      totalRevenueMinor:
        decimalToMinorUnits(
          totalRevenue
            ._sum.amount ??
          zero
        ),

      monthRevenueMinor:
        decimalToMinorUnits(
          monthRevenue
            ._sum.amount ??
          zero
        ),

      pendingAmountMinor:
        decimalToMinorUnits(
          pending
            ._sum.amount ??
          zero
        ),

      pendingCount:
        pending._count,
    };
  }
}
