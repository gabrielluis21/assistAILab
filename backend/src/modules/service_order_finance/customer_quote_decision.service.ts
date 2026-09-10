import {
  FinancialAuditOrigin,
  OperationType,
  Prisma,
  QuoteDecision,
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
  NotFoundError,
} from '../../core/utils/errors.js';

import {
  serviceOrderCustomerRelationshipService,
} from '../customer_relationship/service_order_customer_relationship.service.js';

import {
  deriveCustomerQuoteDecisionPlan,
} from './customer_quote_decision.rules.js';

import type {
  FinanceCommandResult,
} from './service_order_finance.service.js';

export type ExactCustomerQuoteDecisionInput = {
  quoteRevisionId:
    string;

  decision:
    'APPROVE' |
    'REJECT';

  reason?:
    string;
};

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

export class CustomerQuoteDecisionFinanceService {
  async decideExactQuoteRevision(
    customerId:
      string,
    actorUserId:
      string,
    operationId:
      string,
    serviceOrderId:
      string,
    input:
      ExactCustomerQuoteDecisionInput
  ): Promise<FinanceCommandResult> {
    /**
     * CUSTOMER JWT has no organizationId.
     *
     * Resolve tenant from the authoritative ServiceOrder while
     * constraining by the authenticated Customer identity.
     * The same tuple is revalidated under FOR UPDATE after H02.
     */
    const resourceContext =
      await prisma
        .serviceOrder
        .findFirst({
          where: {
            id:
              serviceOrderId,

            customerId,
          },

          select: {
            organizationId:
              true,
          },
        });

    if (
      !resourceContext
    ) {
      throw new NotFoundError(
        'Service Order not found'
      );
    }

    const organizationId =
      resourceContext
        .organizationId;

    const endpoint =
      `/api/v1/service-orders/${serviceOrderId}/quote-decision`;

    const command =
      'FIN_F02_CUSTOMER_QUOTE_DECISION';

    const requestHash =
      computeCanonicalHash({
        serviceOrderId,
        quoteRevisionId:
          input.quoteRevisionId,
        decision:
          input.decision,
        reason:
          input.reason ??
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
        async (tx) => {
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
           * Frozen lock order:
           * H02 -> ServiceOrder -> QuoteRevision.
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
                    AND customerId =
                    ${customerId}
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

                  customerId,

                  organizationId,
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
            order.currentQuoteRevisionId !==
            input.quoteRevisionId
          ) {
            return complete(
              409,
              {
                error:
                  'QUOTE_REVISION_NOT_CURRENT',
              } as
                Prisma.InputJsonValue
            );
          }

          const decision =
            input.decision ===
              'APPROVE'
              ? QuoteDecision
                  .APPROVE
              : QuoteDecision
                  .REJECT;

          const plan =
            deriveCustomerQuoteDecisionPlan(
              order.status,
              decision
            );

          if (!plan) {
            return complete(
              409,
              {
                error:
                  'QUOTE_DECISION_STATUS_CONFLICT',

                currentStatus:
                  order.status,
              } as
                Prisma.InputJsonValue
            );
          }

          const lockedRevision =
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
                  WHERE id =
                    ${input.quoteRevisionId}
                    AND serviceOrderId =
                    ${order.id}
                  FOR UPDATE
                `
              );

          if (
            lockedRevision.length !==
            1
          ) {
            return complete(
              409,
              {
                error:
                  'QUOTE_REVISION_NOT_AVAILABLE',
              } as
                Prisma.InputJsonValue
            );
          }

          const quoteRevision =
            await tx
              .serviceOrderQuoteRevision
              .findFirst({
                where: {
                  id:
                    input.quoteRevisionId,

                  serviceOrderId:
                    order.id,

                  organizationId:
                    order.organizationId,

                  customerId:
                    order.customerId,
                },
              });

          if (
            !quoteRevision
          ) {
            return complete(
              409,
              {
                error:
                  'QUOTE_REVISION_NOT_AVAILABLE',
              } as
                Prisma.InputJsonValue
            );
          }

          /**
           * State/history coherence.
           */
          if (
            order.status ===
              ServiceOrderStatus
                .AGUARDANDO_APROVACAO &&
            order.lastApprovedQuoteRevisionId !==
              null
          ) {
            return complete(
              409,
              {
                error:
                  'QUOTE_APPROVAL_HISTORY_CONFLICT',
              } as
                Prisma.InputJsonValue
            );
          }

          if (
            order.status ===
              ServiceOrderStatus
                .AGUARDANDO_REAPROVACAO &&
            order.lastApprovedQuoteRevisionId ===
              null
          ) {
            return complete(
              409,
              {
                error:
                  'REAPPROVAL_REQUIRES_PRIOR_APPROVED_REVISION',
              } as
                Prisma.InputJsonValue
            );
          }

          const existingDecision =
            await tx
              .customerQuoteDecision
              .findUnique({
                where: {
                  quoteRevisionId:
                    quoteRevision.id,
                },
              });

          if (
            existingDecision
          ) {
            return complete(
              409,
              {
                error:
                  'QUOTE_REVISION_ALREADY_DECIDED',

                decision:
                  existingDecision
                    .decision,
              } as
                Prisma.InputJsonValue
            );
          }

          const persistedDecision =
            await tx
              .customerQuoteDecision
              .create({
                data: {
                  quoteRevisionId:
                    quoteRevision.id,

                  serviceOrderId:
                    order.id,

                  organizationId:
                    order.organizationId,

                  customerId:
                    order.customerId,

                  decision,

                  reason:
                    input.reason ??
                    null,

                  decidedByUserId:
                    actorUserId,
                },
              });

          let updatedOrder =
            order;

          if (
            plan
              .changesServiceOrder
          ) {
            const updateResult =
              await tx
                .serviceOrder
                .updateMany({
                  where: {
                    id:
                      order.id,

                    organizationId:
                      order.organizationId,

                    customerId:
                      order.customerId,

                    status:
                      plan
                        .previousStatus,

                    currentQuoteRevisionId:
                      quoteRevision.id,
                  },

                  data: {
                    status:
                      plan
                        .nextStatus,

                    ...(
                      plan
                        .setLastApprovedToCurrent
                        ? {
                            lastApprovedQuoteRevisionId:
                              quoteRevision.id,
                          }
                        : {}
                    ),
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
                    plan
                      .previousStatus,

                  newStatus:
                    plan
                      .nextStatus,

                  changedById:
                    actorUserId,

                  notes:
                    input.reason ??
                    (
                      decision ===
                        QuoteDecision
                          .APPROVE
                        ? 'FIN-F02 quote approved by customer'
                        : 'FIN-F02 initial quote rejected by customer'
                    ),
                },
              });

            if (
              plan
                .initialRejection
            ) {
              /**
               * Preserve the existing cancellation policy and
               * specialized CRM event. Do NOT also emit generic
               * SERVICE_ORDER_CANCELLED.
               */
              await serviceOrderCustomerRelationshipService
                .registerNotApproved(
                  {
                    serviceOrderId:
                      order.id,

                    customerId:
                      order.customerId,

                    organizationId:
                      order.organizationId,

                    previousStatus:
                      plan
                        .previousStatus,

                    changedById:
                      actorUserId,

                    reason:
                      input.reason,
                  },

                  tx
                );
            } else {
              await serviceOrderCustomerRelationshipService
                .registerStatusTransition(
                  {
                    serviceOrderId:
                      order.id,

                    customerId:
                      order.customerId,

                    organizationId:
                      order.organizationId,

                    previousStatus:
                      plan
                        .previousStatus,

                    newStatus:
                      plan
                        .nextStatus,
                  },

                  tx
                );
            }

            updatedOrder =
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
          }

          await tx
            .financialAuditEvent
            .create({
              data: {
                organizationId:
                  order.organizationId,

                serviceOrderId:
                  order.id,

                actorUserId,

                origin:
                  FinancialAuditOrigin
                    .USER_COMMAND,

                eventType:
                  decision ===
                    QuoteDecision.APPROVE
                    ? 'QUOTE_APPROVED'
                    : 'QUOTE_REJECTED',

                entityType:
                  'CUSTOMER_QUOTE_DECISION',

                entityId:
                  persistedDecision.id,

                operationId,

                ordinal:
                  1,

                metadata: {
                  quoteRevisionId:
                    quoteRevision.id,

                  revisionNumber:
                    quoteRevision
                      .revisionNumber,

                  decision,

                  previousStatus:
                    plan
                      .previousStatus,

                  resultingStatus:
                    plan
                      .nextStatus,

                  lastApprovedQuoteRevisionId:
                    plan
                      .setLastApprovedToCurrent
                      ? quoteRevision.id
                      : order
                          .lastApprovedQuoteRevisionId,
                },
              },
            });

          const responseBody = {
            order: {
              id:
                updatedOrder.id,

              status:
                plan
                  .changesServiceOrder
                  ? plan
                      .nextStatus
                  : order.status,

              financeCoreVersion:
                updatedOrder
                  .financeCoreVersion,

              currentQuoteRevisionId:
                updatedOrder
                  .currentQuoteRevisionId,

              lastApprovedQuoteRevisionId:
                plan
                  .setLastApprovedToCurrent
                  ? quoteRevision.id
                  : updatedOrder
                      .lastApprovedQuoteRevisionId,
            },

            quoteDecision: {
              id:
                persistedDecision.id,

              quoteRevisionId:
                persistedDecision
                  .quoteRevisionId,

              decision:
                persistedDecision
                  .decision,

              reason:
                persistedDecision
                  .reason,

              decidedAt:
                persistedDecision
                  .decidedAt
                  .toISOString(),
            },
          } as
            Prisma.InputJsonValue;

          return complete(
            200,
            responseBody
          );
        }
      );
  }
}

export const customerQuoteDecisionFinanceService =
  new CustomerQuoteDecisionFinanceService();
