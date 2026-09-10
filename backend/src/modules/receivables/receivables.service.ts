import {
  FinancialAuditOrigin,
  PaymentStatus,
  Prisma,
  ReceivableLifecycleStatus,
} from '@prisma/client';

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
} from '../../core/money/money.js';

import {
  ConflictError,
  NotFoundError,
} from '../../core/utils/errors.js';

import {
  buildReceivableReschedulePlan,
} from './receivables.fin-f02.rules.js';

import type {
  CancelReceivableInput,
  RescheduleReceivableInput,
} from './receivables.schema.js';

export type ReceivableCommandResult = {
  statusCode:
    number;

  body:
    Prisma.InputJsonValue;
};

type CommandIdentity = {
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

function replayResult(
  responseStatus:
    number,
  responseBody:
    Prisma.JsonValue
): ReceivableCommandResult {
  return {
    statusCode:
      responseStatus,

    body:
      responseBody as
        Prisma.InputJsonValue,
  };
}

async function completeCommand(
  tx:
    Prisma.TransactionClient,
  identity:
    CommandIdentity,
  leaseToken:
    string,
  statusCode:
    number,
  body:
    Prisma.InputJsonValue
): Promise<
  ReceivableCommandResult
> {
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

async function reserveCommand(
  identity:
    CommandIdentity
) {
  const idempotency =
    new IdempotencyService(
      prisma
    );

  const reservation =
    await idempotency
      .reserveOrReplay(
        identity
      );

  if (
    reservation.kind ===
    'REPLAY'
  ) {
    return {
      reservation:
        null,

      replay:
        replayResult(
          reservation
            .responseStatus,
          reservation
            .responseBody
        ),
    };
  }

  if (
    reservation.kind ===
    'KEY_REUSE'
  ) {
    throw new ConflictError(
      'IDEMPOTENCY_KEY_REUSE'
    );
  }

  if (
    reservation.kind ===
    'IN_PROGRESS'
  ) {
    throw new ConflictError(
      'IDEMPOTENCY_IN_PROGRESS'
    );
  }

  if (
    reservation.kind !==
    'ACQUIRED'
  ) {
    throw new Error(
      'Unexpected idempotency state'
    );
  }

  return {
    reservation,
    replay:
      null,
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

        status:
          true,

        financeCoreVersion:
          true,
      },
    });
}

async function lockReceivable(
  tx:
    Prisma.TransactionClient,
  receivableId:
    string,
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
          FROM receivables
          WHERE id =
            ${receivableId}
            AND serviceOrderId =
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
    .receivable
    .findFirst({
      where: {
        id:
          receivableId,

        serviceOrderId,

        organizationId,
      },
    });
}

async function lockSchedulesAndInstallments(
  tx:
    Prisma.TransactionClient,
  receivableId:
    string,
  currentScheduleVersion:
    number
) {
  const schedules =
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
            ${receivableId}
          ORDER BY
            version,
            id
          FOR UPDATE
        `
      );

  const currentSchedule =
    schedules.filter(
      (
        schedule
      ) =>
        schedule.version ===
        currentScheduleVersion
    );

  if (
    currentSchedule.length !==
    1
  ) {
    return null;
  }

  const installments =
    await tx
      .$queryRaw<
        Array<{
          id:
            string;

          scheduleId:
            string;

          scheduleVersion:
            number;

          sequence:
            number;

          amount:
            Prisma.Decimal;

          dueDate:
            Date;
        }>
      >(
        Prisma.sql`
          SELECT
            id,
            scheduleId,
            scheduleVersion,
            sequence,
            amount,
            dueDate
          FROM receivable_installments
          WHERE receivableId =
            ${receivableId}
          ORDER BY
            scheduleVersion,
            sequence,
            id
          FOR UPDATE
        `
      );

  return {
    schedules,
    currentSchedule:
      currentSchedule[0],

    installments,

    currentInstallments:
      installments.filter(
        (
          installment
        ) =>
          installment
            .scheduleVersion ===
          currentScheduleVersion &&
          installment
            .scheduleId ===
          currentSchedule[0]
            .id
      ),
  };
}

async function lockServiceOrderPayments(
  tx:
    Prisma.TransactionClient,
  serviceOrderId:
    string,
  organizationId:
    string
) {
  return tx
    .$queryRaw<
      Array<{
        id:
          string;

        status:
          PaymentStatus;
      }>
    >(
      Prisma.sql`
        SELECT
          id,
          status
        FROM payments
        WHERE serviceOrderId =
          ${serviceOrderId}
          AND organizationId =
            ${organizationId}
        ORDER BY id
        FOR UPDATE
      `
    );
}

async function receivableAllocations(
  tx:
    Prisma.TransactionClient,
  receivableId:
    string
) {
  return tx
    .paymentAllocation
    .findMany({
      where: {
        receivableId,
      },

      select: {
        id:
          true,

        installmentId:
          true,

        amount:
          true,
      },

      orderBy: {
        id:
          'asc',
      },
    });
}

export class ReceivablesFinanceService {
  private async preflight(
    organizationId:
      string,
    receivableId:
      string
  ) {
    const receivable =
      await prisma
        .receivable
        .findFirst({
          where: {
            id:
              receivableId,

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
      !receivable
    ) {
      throw new NotFoundError(
        `Receivable ${receivableId} not found`
      );
    }

    return receivable;
  }

  async reschedule(
    organizationId:
      string,
    actorUserId:
      string,
    operationId:
      string,
    receivableId:
      string,
    input:
      RescheduleReceivableInput
  ): Promise<
    ReceivableCommandResult
  > {
    const preflight =
      await this
        .preflight(
          organizationId,
          receivableId
        );

    const identity:
      CommandIdentity = {
        operationId,
        actorUserId,
        organizationId,

        command:
          'FIN_F02_RECEIVABLE_RESCHEDULE',

        endpoint:
          `/api/v1/receivables/${receivableId}/reschedule`,

        requestHash:
          computeCanonicalHash({
            receivableId,

            dueDate:
              input.dueDate,

            reason:
              input.reason,
          }),
      };

    const {
      reservation,
      replay,
    } =
      await reserveCommand(
        identity
      );

    if (
      replay
    ) {
      return replay;
    }

    if (
      !reservation
    ) {
      throw new Error(
        'Missing acquired idempotency reservation'
      );
    }

    return prisma
      .$transaction(
        async (
          tx
        ) => {
          const serviceOrder =
            await lockServiceOrder(
              tx,
              preflight
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

          if (
            serviceOrder
              .financeCoreVersion !==
            2
          ) {
            return completeCommand(
              tx,
              identity,
              reservation
                .leaseToken,
              409,
              {
                error:
                  'FIN_F02_ORDER_REQUIRED',
              } as
                Prisma.InputJsonValue
            );
          }

          const receivable =
            await lockReceivable(
              tx,
              receivableId,
              serviceOrder.id,
              organizationId
            );

          if (
            !receivable
          ) {
            return completeCommand(
              tx,
              identity,
              reservation
                .leaseToken,
              404,
              {
                error:
                  'RECEIVABLE_NOT_FOUND',
              } as
                Prisma.InputJsonValue
            );
          }

          if (
            receivable
              .customerId !==
            serviceOrder
              .customerId
          ) {
            return completeCommand(
              tx,
              identity,
              reservation
                .leaseToken,
              409,
              {
                error:
                  'RECEIVABLE_SERVICE_ORDER_AUTHORITY_MISMATCH',
              } as
                Prisma.InputJsonValue
            );
          }

          if (
            receivable
              .lifecycleStatus !==
            ReceivableLifecycleStatus
              .ACTIVE
          ) {
            return completeCommand(
              tx,
              identity,
              reservation
                .leaseToken,
              409,
              {
                error:
                  'RECEIVABLE_NOT_ACTIVE',
              } as
                Prisma.InputJsonValue
            );
          }

          const scheduleState =
            await lockSchedulesAndInstallments(
              tx,
              receivable.id,
              receivable
                .currentScheduleVersion
            );

          if (
            !scheduleState ||
            scheduleState
              .currentInstallments
              .length ===
              0
          ) {
            return completeCommand(
              tx,
              identity,
              reservation
                .leaseToken,
              409,
              {
                error:
                  'CURRENT_RECEIVABLE_SCHEDULE_INVALID',
              } as
                Prisma.InputJsonValue
            );
          }

          /**
           * Frozen global order:
           * ServiceOrder -> Receivable -> Schedule -> Installment
           * -> Payment -> allocation aggregate.
           */
          await lockServiceOrderPayments(
            tx,
            serviceOrder.id,
            organizationId
          );

          const allocations =
            await receivableAllocations(
              tx,
              receivable.id
            );

          const allocatedTotalMinor =
            allocations.reduce(
              (
                sum,
                allocation
              ) =>
                sum +
                decimalToMinorUnits(
                  allocation.amount
                ),
              0
            );

          /**
           * FIN-F02-R01
           *
           * Any effective allocation freezes normal reschedule. The
           * ServiceOrder/Receivable/Schedule/Installment/Payment locks
           * are already held at this point, so this decision is made
           * from serialized financial state before any new schedule,
           * installment, Receivable version or audit row is created.
           */
          if (
            allocatedTotalMinor !==
            0
          ) {
            return completeCommand(
              tx,
              identity,
              reservation
                .leaseToken,
              409,
              {
                error:
                  'RECEIVABLE_RESCHEDULE_REQUIRES_ZERO_ALLOCATIONS',

                allocatedMinor:
                  allocatedTotalMinor,
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
            allocations
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
                  decimalToMinorUnits(
                    allocation
                      .amount
                  )
              );
          }

          let plan:
            ReturnType<
              typeof buildReceivableReschedulePlan
            >;

          try {
            plan =
              buildReceivableReschedulePlan(
                receivable
                  .totalAmount,

                receivable
                  .currentScheduleVersion,

                allocatedTotalMinor,

                scheduleState
                  .currentInstallments
                  .map(
                    (
                      installment
                    ) => ({
                      id:
                        installment.id,

                      amountMinor:
                        decimalToMinorUnits(
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
                  ),

                input.dueDate
              );
          } catch (
            error
          ) {
            return completeCommand(
              tx,
              identity,
              reservation
                .leaseToken,
              409,
              {
                error:
                  error instanceof
                    RangeError
                    ? error.message
                    : 'RECEIVABLE_RESCHEDULE_INVALID',
              } as
                Prisma.InputJsonValue
            );
          }

          if (
            scheduleState
              .currentInstallments
              .length ===
              1 &&
            scheduleState
              .currentInstallments[0]
              .dueDate
              .toISOString()
              .slice(
                0,
                10
              ) ===
              input.dueDate
          ) {
            return completeCommand(
              tx,
              identity,
              reservation
                .leaseToken,
              409,
              {
                error:
                  'RECEIVABLE_RESCHEDULE_DUE_DATE_UNCHANGED',
              } as
                Prisma.InputJsonValue
            );
          }

          const now =
            new Date();

          const schedule =
            await tx
              .receivableSchedule
              .create({
                data: {
                  organizationId:
                    serviceOrder
                      .organizationId,

                  receivableId:
                    receivable.id,

                  version:
                    plan
                      .nextScheduleVersion,

                  createdByUserId:
                    actorUserId,
                },
              });

          const installment =
            await tx
              .receivableInstallment
              .create({
                data: {
                  organizationId:
                    serviceOrder
                      .organizationId,

                  receivableId:
                    receivable.id,

                  scheduleId:
                    schedule.id,

                  scheduleVersion:
                    plan
                      .nextScheduleVersion,

                  sequence:
                    1,

                  amount:
                    plan
                      .outstandingAmount,

                  dueDate:
                    plan.dueDate,
                },
              });

          const updated =
            await tx
              .receivable
              .updateMany({
                where: {
                  id:
                    receivable.id,

                  organizationId,

                  lifecycleStatus:
                    ReceivableLifecycleStatus
                      .ACTIVE,

                  currentScheduleVersion:
                    receivable
                      .currentScheduleVersion,

                  version:
                    receivable.version,
                },

                data: {
                  currentScheduleVersion:
                    plan
                      .nextScheduleVersion,

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
            throw new Error(
              'Receivable changed after FIN-F02 row lock'
            );
          }

          await tx
            .financialAuditEvent
            .createMany({
              data: [
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
                    'RECEIVABLE_RESCHEDULED',

                  entityType:
                    'RECEIVABLE',

                  entityId:
                    receivable.id,

                  operationId,

                  ordinal:
                    1,

                  occurredAt:
                    now,

                  metadata: {
                    previousScheduleVersion:
                      receivable
                        .currentScheduleVersion,

                    newScheduleVersion:
                      plan
                        .nextScheduleVersion,

                    outstandingMinor:
                      plan
                        .outstandingMinor,

                    dueDate:
                      input.dueDate,

                    reason:
                      input.reason,

                    financialStatus:
                      plan
                        .financialStatus,
                  },
                },

                {
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
                    'RECEIVABLE_SCHEDULE_CREATED',

                  entityType:
                    'RECEIVABLE_SCHEDULE',

                  entityId:
                    schedule.id,

                  operationId,

                  ordinal:
                    2,

                  occurredAt:
                    now,

                  metadata: {
                    receivableId:
                      receivable.id,

                    scheduleVersion:
                      plan
                        .nextScheduleVersion,

                    reason:
                      'RESCHEDULE',
                  },
                },

                {
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
                    'RECEIVABLE_INSTALLMENT_CREATED',

                  entityType:
                    'RECEIVABLE_INSTALLMENT',

                  entityId:
                    installment.id,

                  operationId,

                  ordinal:
                    3,

                  occurredAt:
                    now,

                  metadata: {
                    receivableId:
                      receivable.id,

                    scheduleId:
                      schedule.id,

                    scheduleVersion:
                      plan
                        .nextScheduleVersion,

                    sequence:
                      1,

                    amountMinor:
                      plan
                        .outstandingMinor,

                    dueDate:
                      input.dueDate,

                    reason:
                      'RESCHEDULE',
                  },
                },
              ],
            });

          const body = {
            receivable: {
              id:
                receivable.id,

              lifecycleStatus:
                receivable
                  .lifecycleStatus,

              totalAmountMinor:
                decimalToMinorUnits(
                  receivable
                    .totalAmount
                ),

              allocatedMinor:
                allocatedTotalMinor,

              outstandingAmountMinor:
                plan
                  .outstandingMinor,

              financialStatus:
                plan
                  .financialStatus,

              previousScheduleVersion:
                receivable
                  .currentScheduleVersion,

              currentScheduleVersion:
                plan
                  .nextScheduleVersion,

              version:
                receivable.version +
                1,
            },

            schedule: {
              id:
                schedule.id,

              version:
                schedule.version,

              installment: {
                id:
                  installment.id,

                sequence:
                  installment
                    .sequence,

                amountMinor:
                  plan
                    .outstandingMinor,

                dueDate:
                  input.dueDate,
              },
            },
          } as
            Prisma.InputJsonValue;

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

  async cancel(
    organizationId:
      string,
    actorUserId:
      string,
    operationId:
      string,
    receivableId:
      string,
    input:
      CancelReceivableInput
  ): Promise<
    ReceivableCommandResult
  > {
    const preflight =
      await this
        .preflight(
          organizationId,
          receivableId
        );

    const identity:
      CommandIdentity = {
        operationId,
        actorUserId,
        organizationId,

        command:
          'FIN_F02_RECEIVABLE_CANCEL',

        endpoint:
          `/api/v1/receivables/${receivableId}/cancel`,

        requestHash:
          computeCanonicalHash({
            receivableId,

            reason:
              input.reason,
          }),
      };

    const {
      reservation,
      replay,
    } =
      await reserveCommand(
        identity
      );

    if (
      replay
    ) {
      return replay;
    }

    if (
      !reservation
    ) {
      throw new Error(
        'Missing acquired idempotency reservation'
      );
    }

    return prisma
      .$transaction(
        async (
          tx
        ) => {
          const serviceOrder =
            await lockServiceOrder(
              tx,
              preflight
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

          if (
            serviceOrder
              .financeCoreVersion !==
            2
          ) {
            return completeCommand(
              tx,
              identity,
              reservation
                .leaseToken,
              409,
              {
                error:
                  'FIN_F02_ORDER_REQUIRED',
              } as
                Prisma.InputJsonValue
            );
          }

          const receivable =
            await lockReceivable(
              tx,
              receivableId,
              serviceOrder.id,
              organizationId
            );

          if (
            !receivable
          ) {
            return completeCommand(
              tx,
              identity,
              reservation
                .leaseToken,
              404,
              {
                error:
                  'RECEIVABLE_NOT_FOUND',
              } as
                Prisma.InputJsonValue
            );
          }

          if (
            receivable
              .customerId !==
            serviceOrder
              .customerId
          ) {
            return completeCommand(
              tx,
              identity,
              reservation
                .leaseToken,
              409,
              {
                error:
                  'RECEIVABLE_SERVICE_ORDER_AUTHORITY_MISMATCH',
              } as
                Prisma.InputJsonValue
            );
          }

          if (
            receivable
              .lifecycleStatus !==
            ReceivableLifecycleStatus
              .ACTIVE
          ) {
            return completeCommand(
              tx,
              identity,
              reservation
                .leaseToken,
              409,
              {
                error:
                  'RECEIVABLE_NOT_ACTIVE',
              } as
                Prisma.InputJsonValue
            );
          }

          const scheduleState =
            await lockSchedulesAndInstallments(
              tx,
              receivable.id,
              receivable
                .currentScheduleVersion
            );

          if (
            !scheduleState
          ) {
            return completeCommand(
              tx,
              identity,
              reservation
                .leaseToken,
              409,
              {
                error:
                  'CURRENT_RECEIVABLE_SCHEDULE_INVALID',
              } as
                Prisma.InputJsonValue
            );
          }

          const payments =
            await lockServiceOrderPayments(
              tx,
              serviceOrder.id,
              organizationId
            );

          const allocations =
            await receivableAllocations(
              tx,
              receivable.id
            );

          const allocatedMinor =
            allocations.reduce(
              (
                sum,
                allocation
              ) =>
                sum +
                decimalToMinorUnits(
                  allocation
                    .amount
                ),
              0
            );

          if (
            allocatedMinor !==
            0
          ) {
            return completeCommand(
              tx,
              identity,
              reservation
                .leaseToken,
              409,
              {
                error:
                  'RECEIVABLE_HAS_ALLOCATIONS',

                allocatedMinor,
              } as
                Prisma.InputJsonValue
            );
          }

          const blockingPayments =
            payments.filter(
              (
                payment
              ) =>
                payment.status ===
                  PaymentStatus
                    .PENDING ||
                payment.status ===
                  PaymentStatus
                    .CONFIRMED
            );

          if (
            blockingPayments.length !==
            0
          ) {
            return completeCommand(
              tx,
              identity,
              reservation
                .leaseToken,
              409,
              {
                error:
                  'RECEIVABLE_HAS_BLOCKING_PAYMENTS',

                blockingPaymentCount:
                  blockingPayments
                    .length,
              } as
                Prisma.InputJsonValue
            );
          }

          const now =
            new Date();

          const updated =
            await tx
              .receivable
              .updateMany({
                where: {
                  id:
                    receivable.id,

                  organizationId,

                  lifecycleStatus:
                    ReceivableLifecycleStatus
                      .ACTIVE,

                  version:
                    receivable.version,
                },

                data: {
                  lifecycleStatus:
                    ReceivableLifecycleStatus
                      .CANCELLED,

                  cancelledAt:
                    now,

                  cancelledByUserId:
                    actorUserId,

                  cancellationReason:
                    input.reason,

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
            throw new Error(
              'Receivable changed after FIN-F02 row lock'
            );
          }

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
                  'RECEIVABLE_CANCELLED',

                entityType:
                  'RECEIVABLE',

                entityId:
                  receivable.id,

                operationId,

                ordinal:
                  1,

                occurredAt:
                  now,

                metadata: {
                  reason:
                    input.reason,

                  allocatedMinor:
                    0,

                  blockingPaymentCount:
                    0,

                  serviceOrderStatusPreserved:
                    serviceOrder.status,
                },
              },
            });

          const body = {
            receivable: {
              id:
                receivable.id,

              lifecycleStatus:
                'CANCELLED',

              cancelledAt:
                now
                  .toISOString(),

              cancelledByUserId:
                actorUserId,

              cancellationReason:
                input.reason,

              version:
                receivable.version +
                1,

              sourceQuoteRevisionId:
                receivable
                  .sourceQuoteRevisionId,
            },

            serviceOrder: {
              id:
                serviceOrder.id,

              status:
                serviceOrder.status,

              statusChanged:
                false,
            },
          } as
            Prisma.InputJsonValue;

          return completeCommand(
            tx,
            identity,
            reservation
              .leaseToken,
            200,
            body
          );
        }
      );
  }
}

export const receivablesFinanceService =
  new ReceivablesFinanceService();
