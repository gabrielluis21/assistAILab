import {
  FinancialAuditOrigin,
  OperationType,
  Prisma,
  QuoteDecision,
  ReceivableLifecycleStatus,
  ServiceOrderStatus,
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
  recordServiceOrderSyncChange,
} from '../../core/sync/sync_change_log.service.js';

import {
  ConflictError,
} from '../../core/utils/errors.js';

import {
  serviceOrderCustomerRelationshipService,
} from '../customer_relationship/service_order_customer_relationship.service.js';

import {
  commercialScopeFingerprint,
} from './commercial_quote_revision.rules.js';

import {
  approvedQuoteAuthorityFromRevision,
  buildInitialReceivablePlan,
  liveCommercialScopeFingerprint,
} from './mark_ready.rules.js';

import type {
  MarkReadyInput,
} from './mark_ready.schema.js';

import type {
  FinanceCommandResult,
} from './service_order_finance.service.js';

function replayResult(
  responseStatus:
    number,
  responseBody:
    Prisma.JsonValue
): FinanceCommandResult {
  return {
    statusCode:
      responseStatus,

    body:
      responseBody as
        Prisma.InputJsonValue,
  };
}

export class MarkReadyFinanceService {
  async markReadyAndIssueReceivable(
    organizationId:
      string,
    actorUserId:
      string,
    operationId:
      string,
    serviceOrderId:
      string,
    input:
      MarkReadyInput
  ): Promise<FinanceCommandResult> {
    const endpoint =
      `/api/v1/service-orders/${serviceOrderId}/mark-ready`;

    const command =
      'FIN_F02_MARK_READY';

    const requestHash =
      computeCanonicalHash({
        serviceOrderId,
        notes:
          input.notes ??
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

    if (
      reservation.kind ===
      'REPLAY'
    ) {
      return replayResult(
        reservation
          .responseStatus,
        reservation
          .responseBody
      );
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

    return prisma
      .$transaction(
        async (
          tx
        ) => {
          const complete =
            async (
              statusCode:
                number,
              body:
                Prisma.InputJsonValue
            ): Promise<FinanceCommandResult> => {
              await IdempotencyService
                .completeWithinTransaction(
                  tx,
                  {
                    ...identity,

                    leaseToken:
                      reservation
                        .leaseToken,

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
            };

          /**
           * Frozen common lock root:
           * H02 -> ServiceOrder.
           */
          const lockedOrder =
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
            lockedOrder.length !==
            1
          ) {
            return complete(
              404,
              {
                error:
                  'SERVICE_ORDER_NOT_FOUND',
              } as
                Prisma.InputJsonValue
            );
          }

          const order =
            await tx
              .serviceOrder
              .findFirst({
                where: {
                  id:
                    serviceOrderId,

                  organizationId,
                },

                include: {
                  organization: {
                    select: {
                      timezone:
                        true,
                    },
                  },

                  items: {
                    orderBy: [
                      {
                        createdAt:
                          'asc',
                      },
                      {
                        id:
                          'asc',
                      },
                    ],
                  },
                },
              });

          if (!order) {
            return complete(
              404,
              {
                error:
                  'SERVICE_ORDER_NOT_FOUND',
              } as
                Prisma.InputJsonValue
            );
          }

          if (
            order.financeCoreVersion !==
            2
          ) {
            return complete(
              409,
              {
                error:
                  'FIN_F02_ORDER_REQUIRED',
              } as
                Prisma.InputJsonValue
            );
          }

          if (
            order.status !==
            ServiceOrderStatus
              .EM_EXECUCAO
          ) {
            return complete(
              409,
              {
                error:
                  'MARK_READY_REQUIRES_EXECUTION_STATUS',

                currentStatus:
                  order.status,
              } as
                Prisma.InputJsonValue
            );
          }

          if (
            !order
              .lastApprovedQuoteRevisionId
          ) {
            return complete(
              409,
              {
                error:
                  'MARK_READY_REQUIRES_APPROVED_QUOTE',
              } as
                Prisma.InputJsonValue
            );
          }

          const quoteIds =
            Array.from(
              new Set(
                [
                  order
                    .lastApprovedQuoteRevisionId,

                  order
                    .currentQuoteRevisionId,
                ]
                  .filter(
                    (
                      value
                    ): value is string =>
                      typeof value ===
                      'string'
                  )
              )
            )
              .sort(
                (
                  left,
                  right
                ) =>
                  left.localeCompare(
                    right
                  )
              );

          const lockedQuotes =
            await tx
              .$queryRaw<
                Array<{
                  id:
                    string;
                }>
              >(
                Prisma.sql`
                  SELECT id
                  FROM service_order_quote_revisions
                  WHERE id IN (
                    ${Prisma.join(
                      quoteIds
                    )}
                  )
                    AND serviceOrderId =
                      ${order.id}
                  ORDER BY id
                  FOR UPDATE
                `
              );

          if (
            lockedQuotes.length !==
            quoteIds.length
          ) {
            return complete(
              409,
              {
                error:
                  'MARK_READY_QUOTE_HISTORY_INVALID',
              } as
                Prisma.InputJsonValue
            );
          }

          const approvedRevision =
            await tx
              .serviceOrderQuoteRevision
              .findFirst({
                where: {
                  id:
                    order
                      .lastApprovedQuoteRevisionId,

                  serviceOrderId:
                    order.id,

                  organizationId:
                    order
                      .organizationId,

                  customerId:
                    order
                      .customerId,
                },

                include: {
                  decision:
                    true,
                },
              });

          if (
            !approvedRevision ||
            approvedRevision
              .decision
              ?.decision !==
              QuoteDecision
                .APPROVE
          ) {
            return complete(
              409,
              {
                error:
                  'LAST_APPROVED_QUOTE_HISTORY_INVALID',
              } as
                Prisma.InputJsonValue
            );
          }

          if (
            order
              .currentQuoteRevisionId &&
            order
              .currentQuoteRevisionId !==
              order
                .lastApprovedQuoteRevisionId
          ) {
            const currentRevision =
              await tx
                .serviceOrderQuoteRevision
                .findFirst({
                  where: {
                    id:
                      order
                        .currentQuoteRevisionId,

                    serviceOrderId:
                      order.id,

                    organizationId:
                      order
                        .organizationId,

                    customerId:
                      order
                        .customerId,
                  },

                  include: {
                    decision:
                      true,
                  },
                });

            if (
              !currentRevision ||
              currentRevision
                .decision
                ?.decision !==
                QuoteDecision
                  .REJECT
            ) {
              return complete(
                409,
                {
                  error:
                    'MARK_READY_CURRENT_QUOTE_MUST_BE_APPROVED_OR_REJECTED_HISTORY',
                } as
                  Prisma.InputJsonValue
              );
            }
          }

          let authority:
            ReturnType<
              typeof approvedQuoteAuthorityFromRevision
            >;

          try {
            authority =
              approvedQuoteAuthorityFromRevision(
                approvedRevision
              );
          } catch (
            error
          ) {
            return complete(
              409,
              {
                error:
                  error instanceof
                    RangeError
                    ? error.message
                    : 'APPROVED_QUOTE_SNAPSHOT_INVALID',
              } as
                Prisma.InputJsonValue
            );
          }

          if (
            liveCommercialScopeFingerprint(
              order
            ) !==
            commercialScopeFingerprint(
              authority
                .commercialScope
            )
          ) {
            return complete(
              409,
              {
                error:
                  'EXECUTED_SCOPE_DIVERGED_FROM_LAST_APPROVED_QUOTE',
              } as
                Prisma.InputJsonValue
            );
          }

          /**
           * Frozen lock order after QuoteRevision:
           * Receivable -> Schedule -> Installment.
           */
          const existingReceivables =
            await tx
              .$queryRaw<
                Array<{
                  id:
                    string;

                  lifecycleStatus:
                    string;

                  sourceQuoteRevisionId:
                    string;
                }>
              >(
                Prisma.sql`
                  SELECT
                    id,
                    lifecycleStatus,
                    sourceQuoteRevisionId
                  FROM receivables
                  WHERE serviceOrderId =
                    ${order.id}
                  ORDER BY id
                  FOR UPDATE
                `
              );

          if (
            existingReceivables
              .some(
                (
                  receivable
                ) =>
                  receivable
                    .lifecycleStatus ===
                    'ACTIVE'
              )
          ) {
            return complete(
              409,
              {
                error:
                  'ACTIVE_RECEIVABLE_ALREADY_EXISTS',
              } as
                Prisma.InputJsonValue
            );
          }

          if (
            existingReceivables
              .some(
                (
                  receivable
                ) =>
                  receivable
                    .sourceQuoteRevisionId ===
                    approvedRevision.id
              )
          ) {
            return complete(
              409,
              {
                error:
                  'APPROVED_QUOTE_ALREADY_ISSUED',
              } as
                Prisma.InputJsonValue
            );
          }

          const issuedAt =
            new Date();

          let plan:
            ReturnType<
              typeof buildInitialReceivablePlan
            >;

          try {
            plan =
              buildInitialReceivablePlan(
                authority
                  .totalAmount,

                issuedAt,

                order
                  .organization
                  .timezone
              );
          } catch (
            error
          ) {
            return complete(
              409,
              {
                error:
                  error instanceof
                    RangeError
                    ? error.message
                    : 'RECEIVABLE_PLAN_INVALID',
              } as
                Prisma.InputJsonValue
            );
          }

          const receivable =
            await tx
              .receivable
              .create({
                data: {
                  organizationId:
                    order
                      .organizationId,

                  customerId:
                    order
                      .customerId,

                  serviceOrderId:
                    order.id,

                  sourceQuoteRevisionId:
                    approvedRevision.id,

                  totalAmount:
                    new Prisma.Decimal(
                      plan.totalAmount
                    ),

                  lifecycleStatus:
                    ReceivableLifecycleStatus
                      .ACTIVE,

                  currentScheduleVersion:
                    plan
                      .scheduleVersion,

                  version:
                    1,

                  issuedAt:
                    plan.issuedAt,

                  createdByUserId:
                    actorUserId,
                },
              });

          const schedule =
            await tx
              .receivableSchedule
              .create({
                data: {
                  organizationId:
                    order
                      .organizationId,

                  receivableId:
                    receivable.id,

                  version:
                    plan
                      .scheduleVersion,

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
                    order
                      .organizationId,

                  receivableId:
                    receivable.id,

                  scheduleId:
                    schedule.id,

                  scheduleVersion:
                    plan
                      .scheduleVersion,

                  sequence:
                    plan
                      .installment
                      .sequence,

                  amount:
                    new Prisma.Decimal(
                      plan
                        .installment
                        .amount
                    ),

                  dueDate:
                    plan
                      .installment
                      .dueDate,
                },
              });

          const updateResult =
            await tx
              .serviceOrder
              .updateMany({
                where: {
                  id:
                    order.id,

                  organizationId,

                  status:
                    ServiceOrderStatus
                      .EM_EXECUCAO,

                  lastApprovedQuoteRevisionId:
                    approvedRevision.id,
                },

                data: {
                  status:
                    ServiceOrderStatus
                      .PRONTO,
                },
              });

          if (
            updateResult.count !==
            1
          ) {
            throw new Error(
              'Service Order changed after FIN-F02 row lock'
            );
          }

          await tx
            .serviceOrderStatusHistory
            .create({
              data: {
                serviceOrderId:
                  order.id,

                previousStatus:
                  ServiceOrderStatus
                    .EM_EXECUCAO,

                newStatus:
                  ServiceOrderStatus
                    .PRONTO,

                changedById:
                  actorUserId,

                notes:
                  input.notes ??
                  'FIN-F02 MARK READY',
              },
            });

          await serviceOrderCustomerRelationshipService
            .registerStatusTransition(
              {
                serviceOrderId:
                  order.id,

                customerId:
                  order.customerId,

                organizationId:
                  order
                    .organizationId,

                previousStatus:
                  ServiceOrderStatus
                    .EM_EXECUCAO,

                newStatus:
                  ServiceOrderStatus
                    .PRONTO,
              },

              tx
            );

          await tx
            .financialAuditEvent
            .createMany({
              data: [
                {
                  organizationId:
                    order
                      .organizationId,

                  serviceOrderId:
                    order.id,

                  actorUserId,

                  origin:
                    FinancialAuditOrigin
                      .USER_COMMAND,

                  eventType:
                    'SERVICE_ORDER_MARKED_READY',

                  entityType:
                    'SERVICE_ORDER',

                  entityId:
                    order.id,

                  operationId,

                  ordinal:
                    1,

                  occurredAt:
                    issuedAt,

                  metadata: {
                    approvedQuoteRevisionId:
                      approvedRevision.id,

                    notes:
                      input.notes ??
                      null,
                  },
                },

                {
                  organizationId:
                    order
                      .organizationId,

                  serviceOrderId:
                    order.id,

                  actorUserId:
                    null,

                  origin:
                    FinancialAuditOrigin
                      .SYSTEM_DERIVED,

                  eventType:
                    'RECEIVABLE_ISSUED',

                  entityType:
                    'RECEIVABLE',

                  entityId:
                    receivable.id,

                  operationId,

                  ordinal:
                    2,

                  occurredAt:
                    issuedAt,

                  metadata: {
                    sourceQuoteRevisionId:
                      approvedRevision.id,

                    totalAmount:
                      plan.totalAmount,
                  },
                },

                {
                  organizationId:
                    order
                      .organizationId,

                  serviceOrderId:
                    order.id,

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
                    3,

                  occurredAt:
                    issuedAt,

                  metadata: {
                    receivableId:
                      receivable.id,

                    scheduleVersion:
                      plan
                        .scheduleVersion,
                  },
                },

                {
                  organizationId:
                    order
                      .organizationId,

                  serviceOrderId:
                    order.id,

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
                    4,

                  occurredAt:
                    issuedAt,

                  metadata: {
                    receivableId:
                      receivable.id,

                    scheduleId:
                      schedule.id,

                    scheduleVersion:
                      plan
                        .scheduleVersion,

                    sequence:
                      plan
                        .installment
                        .sequence,

                    amount:
                      plan
                        .installment
                        .amount,

                    dueDate:
                      plan
                        .installment
                        .dueDate
                        .toISOString()
                        .slice(
                          0,
                          10
                        ),

                    organizationTimeZone:
                      order
                        .organization
                        .timezone,
                  },
                },
              ],
            });

          const updatedOrder =
            await tx
              .serviceOrder
              .findUniqueOrThrow({
                where: {
                  id:
                    order.id,
                },
              });

          await recordServiceOrderSyncChange(
            updatedOrder,
            OperationType.UPDATE,
            tx
          );

          const body = {
            order: {
              id:
                updatedOrder.id,

              status:
                updatedOrder
                  .status,

              currentQuoteRevisionId:
                updatedOrder
                  .currentQuoteRevisionId,

              lastApprovedQuoteRevisionId:
                updatedOrder
                  .lastApprovedQuoteRevisionId,
            },

            receivable: {
              id:
                receivable.id,

              lifecycleStatus:
                receivable
                  .lifecycleStatus,

              sourceQuoteRevisionId:
                receivable
                  .sourceQuoteRevisionId,

              totalAmount:
                receivable
                  .totalAmount
                  .toFixed(
                    2
                  ),

              issuedAt:
                receivable
                  .issuedAt
                  .toISOString(),

              financialStatus:
                'A_RECEBER',
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

                amount:
                  installment
                    .amount
                    .toFixed(
                      2
                    ),

                dueDate:
                  installment
                    .dueDate
                    .toISOString()
                    .slice(
                      0,
                      10
                    ),
              },
            },
          } as
            Prisma.InputJsonValue;

          return complete(
            201,
            body
          );
        }
      );
  }
}

export const markReadyFinanceService =
  new MarkReadyFinanceService();
