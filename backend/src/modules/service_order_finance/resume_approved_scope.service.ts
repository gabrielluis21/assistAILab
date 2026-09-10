import {
  FinancialAuditOrigin,
  MediaEntityType,
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
} from '../../core/utils/errors.js';

import {
  serviceOrderCustomerRelationshipService,
} from '../customer_relationship/service_order_customer_relationship.service.js';

import {
  parseApprovedQuoteSnapshotForResume,
} from './resume_approved_scope.rules.js';

import type {
  ResumeApprovedScopeInput,
} from './resume_approved_scope.schema.js';

import type {
  FinanceCommandResult,
} from './service_order_finance.service.js';

function replayResult(
  responseStatus: number,
  responseBody: Prisma.JsonValue
): FinanceCommandResult {
  return {
    statusCode:
      responseStatus,
    body:
      responseBody as Prisma.InputJsonValue,
  };
}

export class ResumeApprovedScopeService {
  async resumePriorApprovedScope(
    organizationId: string,
    actorUserId: string,
    operationId: string,
    serviceOrderId: string,
    input: ResumeApprovedScopeInput
  ): Promise<FinanceCommandResult> {
    const endpoint =
      `/api/v1/service-orders/${serviceOrderId}/quotes/resume-approved-scope`;

    const command =
      'FIN_F02_RESUME_APPROVED_SCOPE';

    const requestHash =
      computeCanonicalHash({
        serviceOrderId,
        reason:
          input.reason,
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
      await idempotency.reserveOrReplay(
        identity
      );

    if (reservation.kind === 'REPLAY') {
      return replayResult(
        reservation.responseStatus,
        reservation.responseBody
      );
    }

    if (reservation.kind === 'KEY_REUSE') {
      throw new ConflictError(
        'IDEMPOTENCY_KEY_REUSE'
      );
    }

    if (reservation.kind === 'IN_PROGRESS') {
      throw new ConflictError(
        'IDEMPOTENCY_IN_PROGRESS'
      );
    }

    if (reservation.kind !== 'ACQUIRED') {
      throw new Error(
        'Unexpected idempotency state'
      );
    }

    return prisma.$transaction(
      async (tx) => {
        const complete =
          async (
            statusCode: number,
            body: Prisma.InputJsonValue
          ): Promise<FinanceCommandResult> => {
            await IdempotencyService
              .completeWithinTransaction(
                tx,
                {
                  ...identity,
                  leaseToken:
                    reservation.leaseToken,
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

        const lockedOrder =
          await tx.$queryRaw<
            Array<{ id: string }>
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

        if (lockedOrder.length !== 1) {
          return complete(
            404,
            {
              error:
                'SERVICE_ORDER_NOT_FOUND',
            } as Prisma.InputJsonValue
          );
        }

        const order =
          await tx.serviceOrder.findFirst({
            where: {
              id:
                serviceOrderId,
              organizationId,
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
          order.financeCoreVersion !== 2
        ) {
          return complete(
            409,
            {
              error:
                'FIN_F02_ORDER_REQUIRED',
            } as Prisma.InputJsonValue
          );
        }

        if (
          order.status !==
          ServiceOrderStatus
            .AGUARDANDO_REAPROVACAO
        ) {
          return complete(
            409,
            {
              error:
                'RESUME_APPROVED_SCOPE_STATUS_CONFLICT',
              currentStatus:
                order.status,
            } as Prisma.InputJsonValue
          );
        }

        if (
          !order.currentQuoteRevisionId ||
          !order.lastApprovedQuoteRevisionId
        ) {
          return complete(
            409,
            {
              error:
                'RESUME_APPROVED_SCOPE_POINTERS_REQUIRED',
            } as Prisma.InputJsonValue
          );
        }

        if (
          order.currentQuoteRevisionId ===
          order.lastApprovedQuoteRevisionId
        ) {
          return complete(
            409,
            {
              error:
                'RESUME_APPROVED_SCOPE_REQUIRES_REJECTED_LATER_REVISION',
            } as Prisma.InputJsonValue
          );
        }

        const quoteIds =
          [
            order.currentQuoteRevisionId,
            order.lastApprovedQuoteRevisionId,
          ].sort(
            (left, right) =>
              left.localeCompare(right)
          );

        const lockedQuotes =
          await tx.$queryRaw<
            Array<{ id: string }>
          >(
            Prisma.sql`
              SELECT id
              FROM service_order_quote_revisions
              WHERE id IN (
                ${Prisma.join(quoteIds)}
              )
                AND serviceOrderId =
                  ${order.id}
              ORDER BY id
              FOR UPDATE
            `
          );

        if (lockedQuotes.length !== 2) {
          return complete(
            409,
            {
              error:
                'RESUME_APPROVED_SCOPE_QUOTE_HISTORY_INVALID',
            } as Prisma.InputJsonValue
          );
        }

        const [
          currentRevision,
          approvedRevision,
        ] =
          await Promise.all([
            tx.serviceOrderQuoteRevision
              .findFirst({
                where: {
                  id:
                    order.currentQuoteRevisionId,
                  serviceOrderId:
                    order.id,
                  organizationId:
                    order.organizationId,
                  customerId:
                    order.customerId,
                },
                include: {
                  decision:
                    true,
                },
              }),

            tx.serviceOrderQuoteRevision
              .findFirst({
                where: {
                  id:
                    order.lastApprovedQuoteRevisionId,
                  serviceOrderId:
                    order.id,
                  organizationId:
                    order.organizationId,
                  customerId:
                    order.customerId,
                },
                include: {
                  decision:
                    true,
                },
              }),
          ]);

        if (
          !currentRevision ||
          currentRevision.decision?.decision !==
            QuoteDecision.REJECT
        ) {
          return complete(
            409,
            {
              error:
                'CURRENT_QUOTE_MUST_BE_REJECTED',
            } as Prisma.InputJsonValue
          );
        }

        if (
          !approvedRevision ||
          approvedRevision.decision?.decision !==
            QuoteDecision.APPROVE
        ) {
          return complete(
            409,
            {
              error:
                'LAST_APPROVED_QUOTE_HISTORY_INVALID',
            } as Prisma.InputJsonValue
          );
        }

        let restorePlan:
          ReturnType<
            typeof parseApprovedQuoteSnapshotForResume
          >;

        try {
          restorePlan =
            parseApprovedQuoteSnapshotForResume(
              approvedRevision
            );
        } catch (error) {
          return complete(
            409,
            {
              error:
                error instanceof RangeError
                  ? error.message
                  : 'APPROVED_QUOTE_SNAPSHOT_INVALID',
            } as Prisma.InputJsonValue
          );
        }

        const approvedItemIds =
          restorePlan.items.map(
            (item) => item.id
          );

        const existingApprovedIds =
          await tx.serviceOrderItem
            .findMany({
              where: {
                id: {
                  in:
                    approvedItemIds,
                },
              },
              select: {
                id:
                  true,
                serviceOrderId:
                  true,
              },
            });

        if (
          existingApprovedIds.some(
            (item) =>
              item.serviceOrderId !==
              order.id
          )
        ) {
          return complete(
            409,
            {
              error:
                'APPROVED_SCOPE_ITEM_ID_COLLISION',
            } as Prisma.InputJsonValue
          );
        }

        const approvedPartIds =
          Array.from(
            new Set(
              restorePlan.items
                .map(
                  (item) => item.partId
                )
                .filter(
                  (
                    value
                  ): value is string =>
                    typeof value === 'string'
                )
            )
          );

        if (approvedPartIds.length > 0) {
          const existingParts =
            await tx.part.count({
              where: {
                id: {
                  in:
                    approvedPartIds,
                },
              },
            });

          if (
            existingParts !==
            approvedPartIds.length
          ) {
            return complete(
              409,
              {
                error:
                  'APPROVED_SCOPE_PART_NOT_FOUND',
              } as Prisma.InputJsonValue
            );
          }
        }

        /**
         * FIN-F02 commercial evidence integrity.
         *
         * MediaAsset keeps a stable polymorphic target
         * (entityType/entityId) even when its optional relational FK is
         * cleared by ServiceOrderItem onDelete:SetNull.
         *
         * Lock all semantic SERVICE_ORDER_ITEM media targets for the
         * approved scope before mutating live items. This lets resume
         * safely restore only associations whose semantic target is the
         * exact historical item being restored.
         */
        const approvedItemMedia =
          approvedItemIds.length >
            0
            ? await tx.$queryRaw<
                Array<{
                  id: string;
                  entityId: string;
                  serviceOrderId:
                    string |
                    null;
                  serviceOrderItemId:
                    string |
                    null;
                }>
              >(
                Prisma.sql`
                  SELECT
                    id,
                    entityId,
                    serviceOrderId,
                    serviceOrderItemId
                  FROM media_assets
                  WHERE organizationId =
                    ${order.organizationId}
                    AND entityType =
                      ${MediaEntityType.SERVICE_ORDER_ITEM}
                    AND entityId IN (
                      ${Prisma.join(
                        approvedItemIds
                      )}
                    )
                  ORDER BY id ASC
                  FOR UPDATE
                `
              )
            : [];

        for (
          const mediaAsset of
          approvedItemMedia
        ) {
          if (
            mediaAsset
              .serviceOrderId !==
              null &&
            mediaAsset
              .serviceOrderId !==
              order.id
          ) {
            return complete(
              409,
              {
                error:
                  'MEDIA_SERVICE_ORDER_AUTHORITY_MISMATCH',
                mediaAssetId:
                  mediaAsset.id,
              } as Prisma.InputJsonValue
            );
          }

          if (
            mediaAsset
              .serviceOrderItemId !==
              null &&
            mediaAsset
              .serviceOrderItemId !==
              mediaAsset.entityId
          ) {
            return complete(
              409,
              {
                error:
                  'MEDIA_SERVICE_ORDER_ITEM_TARGET_MISMATCH',
                mediaAssetId:
                  mediaAsset.id,
              } as Prisma.InputJsonValue
            );
          }
        }

        await tx.serviceOrderItem.deleteMany({
          where: {
            serviceOrderId:
              order.id,
            id: {
              notIn:
                approvedItemIds,
            },
          },
        });

        for (const item of restorePlan.items) {
          await tx.serviceOrderItem.upsert({
            where: {
              id:
                item.id,
            },
            create: {
              id:
                item.id,
              serviceOrderId:
                order.id,
              partId:
                item.partId,
              description:
                item.description,
              quantity:
                item.quantity,
              unitPrice:
                new Prisma.Decimal(
                  item.unitPrice
                ),
              totalPrice:
                new Prisma.Decimal(
                  item.totalPrice
                ),
            },
            update: {
              partId:
                item.partId,
              description:
                item.description,
              quantity:
                item.quantity,
              unitPrice:
                new Prisma.Decimal(
                  item.unitPrice
                ),
              totalPrice:
                new Prisma.Decimal(
                  item.totalPrice
                ),
            },
          });
        }

        /**
         * Re-link only semantic item media whose FK was previously
         * cleared. Already-valid associations remain untouched.
         *
         * Rows are still locked from the query above, so a failed CAS is
         * treated as an unexpected state change and rolls back the command.
         */
        for (
          const mediaAsset of
          approvedItemMedia
        ) {
          if (
            mediaAsset
              .serviceOrderItemId !==
            null
          ) {
            continue;
          }

          const relinkResult =
            await tx.mediaAsset
              .updateMany({
                where: {
                  id:
                    mediaAsset.id,

                  organizationId:
                    order.organizationId,

                  entityType:
                    MediaEntityType
                      .SERVICE_ORDER_ITEM,

                  entityId:
                    mediaAsset.entityId,

                  serviceOrderItemId:
                    null,
                },

                data: {
                  serviceOrderItemId:
                    mediaAsset.entityId,
                },
              });

          if (
            relinkResult.count !==
            1
          ) {
            throw new Error(
              'Media association changed after FIN-F02 media row lock'
            );
          }
        }

        const updateResult =
          await tx.serviceOrder.updateMany({
            where: {
              id:
                order.id,
              organizationId,
              status:
                ServiceOrderStatus
                  .AGUARDANDO_REAPROVACAO,
              currentQuoteRevisionId:
                order.currentQuoteRevisionId,
              lastApprovedQuoteRevisionId:
                order.lastApprovedQuoteRevisionId,
            },
            data: {
              diagnosis:
                restorePlan.diagnosis,
              totalAmount:
                new Prisma.Decimal(
                  restorePlan.totalAmount
                ),
              status:
                ServiceOrderStatus
                  .EM_EXECUCAO,
            },
          });

        if (updateResult.count !== 1) {
          throw new Error(
            'Service Order changed after FIN-F02 row lock'
          );
        }

        await tx.serviceOrderStatusHistory.create({
          data: {
            serviceOrderId:
              order.id,
            previousStatus:
              ServiceOrderStatus
                .AGUARDANDO_REAPROVACAO,
            newStatus:
              ServiceOrderStatus
                .EM_EXECUCAO,
            changedById:
              actorUserId,
            notes:
              input.reason,
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
                  .AGUARDANDO_REAPROVACAO,
              newStatus:
                ServiceOrderStatus
                  .EM_EXECUCAO,
            },
            tx
          );

        await tx.financialAuditEvent.create({
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
              'PRIOR_APPROVED_SCOPE_RESUMED',
            entityType:
              'SERVICE_ORDER_QUOTE_REVISION',
            entityId:
              approvedRevision.id,
            operationId,
            ordinal:
              1,
            metadata: {
              rejectedCurrentQuoteRevisionId:
                currentRevision.id,
              resumedApprovedQuoteRevisionId:
                approvedRevision.id,
              currentQuoteRevisionIdPreserved:
                true,
              reason:
                input.reason,
            },
          },
        });

        const updatedOrder =
          await tx.serviceOrder
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
              updatedOrder.financeCoreVersion,
            currentQuoteRevisionId:
              updatedOrder.currentQuoteRevisionId,
            lastApprovedQuoteRevisionId:
              updatedOrder.lastApprovedQuoteRevisionId,
            totalAmount:
              updatedOrder.totalAmount.toFixed(2),
          },
          resumedApprovedQuoteRevision: {
            id:
              approvedRevision.id,
            revisionNumber:
              approvedRevision.revisionNumber,
          },
          rejectedCurrentQuoteRevision: {
            id:
              currentRevision.id,
            revisionNumber:
              currentRevision.revisionNumber,
          },
        } as Prisma.InputJsonValue;

        return complete(
          200,
          body
        );
      }
    );
  }
}

export const resumeApprovedScopeService =
  new ResumeApprovedScopeService();
