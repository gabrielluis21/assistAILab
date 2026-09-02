import {
  FinancialAuditOrigin,
  OperationType,
  Prisma,
  QuoteChangeType,
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

import type {
  PublishQuoteInput,
} from './service_order_finance.schema.js';

export type FinanceCommandResult = {
  statusCode: number;
  body: Prisma.InputJsonValue;
};

function replayResult(
  responseStatus: number,
  responseBody: Prisma.JsonValue
): FinanceCommandResult {
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
): FinanceCommandResult | null {
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

function moneyText(
  value: Prisma.Decimal
): string {
  return value.toFixed(2);
}

export class ServiceOrderFinanceService {
  async publishInitialQuote(
    organizationId: string,
    actorUserId: string,
    operationId: string,
    serviceOrderId: string,
    input: PublishQuoteInput
  ): Promise<FinanceCommandResult> {
    const endpoint =
      `/api/v1/service-orders/${serviceOrderId}/quotes/publish`;

    const command =
      'FIN_F02_QUOTE_PUBLISH';

    const requestHash =
      computeCanonicalHash({
        serviceOrderId,
        changeReason:
          input.changeReason ??
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
        const complete =
          async (
            statusCode: number,
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
         * FIN-F02 common lock root.
         *
         * H02 lease reservation occurred before the transaction.
         */
        const locked =
          await tx.$queryRaw<
            Array<{
              id: string;
            }>
          >(
            Prisma.sql`
              SELECT id
              FROM service_orders
              WHERE id = ${serviceOrderId}
                AND organizationId = ${organizationId}
              FOR UPDATE
            `
          );

        if (
          locked.length !==
          1
        ) {
          return complete(
            404,
            {
              error:
                'SERVICE_ORDER_NOT_FOUND',
            } as Prisma.InputJsonValue
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

                  include: {
                    part:
                      true,
                  },
                },
              },
            });

        if (!order) {
          return complete(
            404,
            {
              error:
                'SERVICE_ORDER_NOT_FOUND',
            } as Prisma.InputJsonValue
          );
        }

        if (
          order.financeCoreVersion !==
            null &&
          order.financeCoreVersion !==
            2
        ) {
          return complete(
            409,
            {
              error:
                'UNSUPPORTED_FINANCE_CORE_VERSION',
            } as Prisma.InputJsonValue
          );
        }

        if (
          order.status !==
          ServiceOrderStatus
            .DIAGNOSTICO
        ) {
          return complete(
            409,
            {
              error:
                'QUOTE_PUBLISH_STATUS_CONFLICT',
              currentStatus:
                order.status,
              requiredStatus:
                ServiceOrderStatus
                  .DIAGNOSTICO,
            } as Prisma.InputJsonValue
          );
        }

        if (
          order.currentQuoteRevisionId ||
          order.lastApprovedQuoteRevisionId
        ) {
          return complete(
            409,
            {
              error:
                'INITIAL_QUOTE_ALREADY_PUBLISHED',
            } as Prisma.InputJsonValue
          );
        }

        /**
         * Detect pointer/history inconsistency fail-closed.
         */
        const existingRevision =
          await tx
            .serviceOrderQuoteRevision
            .findFirst({
              where: {
                serviceOrderId:
                  order.id,
              },
              select: {
                id:
                  true,
              },
            });

        if (
          existingRevision
        ) {
          return complete(
            409,
            {
              error:
                'QUOTE_REVISION_HISTORY_CONFLICT',
            } as Prisma.InputJsonValue
          );
        }

        const serviceItems =
          order.items.map(
            (item) => ({
              id:
                item.id,
              partId:
                item.partId,
              description:
                item.description,
              quantity:
                item.quantity,
              unitPrice:
                moneyText(
                  item.unitPrice
                ),
              totalPrice:
                moneyText(
                  item.totalPrice
                ),
            })
          );

        const partMap =
          new Map<
            string,
            {
              id: string;
              name: string;
              sku: string;
              price: string;
            }
          >();

        for (
          const item of
          order.items
        ) {
          if (
            item.part
          ) {
            partMap.set(
              item.part.id,
              {
                id:
                  item.part.id,
                name:
                  item.part.name,
                sku:
                  item.part.sku,
                price:
                  moneyText(
                    item.part.price
                  ),
              }
            );
          }
        }

        const parts =
          Array.from(
            partMap.values()
          )
            .sort(
              (
                left,
                right
              ) =>
                left.id
                  .localeCompare(
                    right.id
                  )
            );

        const totalAmount =
          moneyText(
            order.totalAmount
          );

        const quoteSnapshot = {
          snapshotVersion:
            1,
          serviceOrderId:
            order.id,
          organizationId:
            order.organizationId,
          customerId:
            order.customerId,
          diagnosis:
            order.diagnosis ??
            null,
          totalAmount,
          serviceItems,
          parts,
        };

        const quoteHash =
          computeCanonicalHash(
            quoteSnapshot
          );

        const quoteRevision =
          await tx
            .serviceOrderQuoteRevision
            .create({
              data: {
                serviceOrderId:
                  order.id,
                organizationId:
                  order.organizationId,
                customerId:
                  order.customerId,
                revisionNumber:
                  1,
                diagnosisSnapshot:
                  order.diagnosis ??
                  null,
                serviceItemsSnapshot:
                  serviceItems as
                    Prisma.InputJsonValue,
                partsSnapshot:
                  parts as
                    Prisma.InputJsonValue,
                totalAmount:
                  order.totalAmount,
                changeType:
                  QuoteChangeType
                    .INITIAL,
                changeReason:
                  input.changeReason ??
                  null,
                quoteSnapshot:
                  quoteSnapshot as
                    Prisma.InputJsonValue,
                quoteHash,
                createdByUserId:
                  actorUserId,
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
                    .DIAGNOSTICO,
                currentQuoteRevisionId:
                  null,
              },

              data: {
                financeCoreVersion:
                  2,
                currentQuoteRevisionId:
                  quoteRevision.id,
                status:
                  ServiceOrderStatus
                    .AGUARDANDO_APROVACAO,
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
                  .DIAGNOSTICO,
              newStatus:
                ServiceOrderStatus
                  .AGUARDANDO_APROVACAO,
              changedById:
                actorUserId,
              notes:
                input.changeReason ??
                'FIN-F02 initial quote published',
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
                order.organizationId,
              previousStatus:
                ServiceOrderStatus
                  .DIAGNOSTICO,
              newStatus:
                ServiceOrderStatus
                  .AGUARDANDO_APROVACAO,
            },
            tx
          );

        /**
         * Audit is append-only at DB level and belongs to the
         * same transaction as the commercial mutation.
         */
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
                'QUOTE_PUBLISHED',
              entityType:
                'SERVICE_ORDER_QUOTE_REVISION',
              entityId:
                quoteRevision.id,
              operationId,
              ordinal:
                1,
              metadata: {
                revisionNumber:
                  1,
                changeType:
                  QuoteChangeType
                    .INITIAL,
                quoteHash,
              },
            },
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
              updatedOrder.status,
            financeCoreVersion:
              updatedOrder
                .financeCoreVersion,
            currentQuoteRevisionId:
              updatedOrder
                .currentQuoteRevisionId,
            lastApprovedQuoteRevisionId:
              updatedOrder
                .lastApprovedQuoteRevisionId,
          },

          quoteRevision: {
            id:
              quoteRevision.id,
            revisionNumber:
              quoteRevision
                .revisionNumber,
            changeType:
              quoteRevision
                .changeType,
            totalAmount,
            quoteHash:
              quoteRevision
                .quoteHash,
            createdAt:
              quoteRevision
                .createdAt
                .toISOString(),
          },
        } as Prisma.InputJsonValue;

        return complete(
          201,
          body
        );
      }
    );
  }
}
