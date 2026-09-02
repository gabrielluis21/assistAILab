import {
  FinancialAuditOrigin,
  OperationType,
  Prisma,
  QuoteChangeType,
  QuoteDecision,
  ServiceOrderStatus,
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
  recordServiceOrderSyncChange,
} from '../../core/sync/sync_change_log.service.js';

import {
  ConflictError,
} from '../../core/utils/errors.js';

import {
  serviceOrderCustomerRelationshipService,
} from '../customer_relationship/service_order_customer_relationship.service.js';

import {
  calculateCommercialLineTotalMinor,
  calculateCommercialTotalMinor,
  commercialScopeFingerprint,
  decimalTextToMinor,
  moneyMinorToDecimalText,
  type CommercialSemanticLine,
  type CommercialSemanticScope,
} from './commercial_quote_revision.rules.js';

import type {
  PublishCommercialQuoteRevisionInput,
} from './commercial_quote_revision.schema.js';

import type {
  FinanceCommandResult,
} from './service_order_finance.service.js';

type PlannedItem = {
  id:
    string;

  existing:
    boolean;

  partId:
    string |
    null;

  description:
    string;

  quantity:
    number;

  unitPriceMinor:
    number;

  totalPriceMinor:
    bigint;
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

function prismaMoneyToMinor(
  value:
    Prisma.Decimal
): bigint {
  return decimalTextToMinor(
    value.toFixed(2)
  );
}

function semanticLineFromStored(
  item: {
    partId:
      string |
      null;

    description:
      string;

    quantity:
      number;

    unitPrice:
      Prisma.Decimal;

    totalPrice:
      Prisma.Decimal;
  }
): CommercialSemanticLine {
  return {
    partId:
      item.partId,

    description:
      item.description,

    quantity:
      item.quantity,

    unitPriceMinor:
      Number(
        prismaMoneyToMinor(
          item.unitPrice
        )
      ),

    totalPriceMinor:
      Number(
        prismaMoneyToMinor(
          item.totalPrice
        )
      ),
  };
}

function semanticLineFromPlanned(
  item:
    PlannedItem
): CommercialSemanticLine {
  return {
    partId:
      item.partId,

    description:
      item.description,

    quantity:
      item.quantity,

    unitPriceMinor:
      item.unitPriceMinor,

    totalPriceMinor:
      Number(
        item.totalPriceMinor
      ),
  };
}

function semanticScopeFromApprovedRevision(
  revision: {
    diagnosisSnapshot:
      string |
      null;

    totalAmount:
      Prisma.Decimal;

    serviceItemsSnapshot:
      Prisma.JsonValue;
  }
): CommercialSemanticScope {
  if (
    !Array.isArray(
      revision
        .serviceItemsSnapshot
    )
  ) {
    throw new ConflictError(
      'APPROVED_QUOTE_SNAPSHOT_INVALID'
    );
  }

  const items:
    CommercialSemanticLine[] =
      revision
        .serviceItemsSnapshot
        .map(
          (
            raw
          ) => {
            if (
              !raw ||
              typeof raw !==
                'object' ||
              Array.isArray(
                raw
              )
            ) {
              throw new ConflictError(
                'APPROVED_QUOTE_SNAPSHOT_INVALID'
              );
            }

            const record =
              raw as
                Record<
                  string,
                  unknown
                >;

            if (
              (
                record.partId !==
                  null &&
                typeof record.partId !==
                  'string'
              ) ||
              typeof record.description !==
                'string' ||
              typeof record.quantity !==
                'number' ||
              typeof record.unitPrice !==
                'string' ||
              typeof record.totalPrice !==
                'string'
            ) {
              throw new ConflictError(
                'APPROVED_QUOTE_SNAPSHOT_INVALID'
              );
            }

            const unitMinor =
              decimalTextToMinor(
                record
                  .unitPrice
              );

            const totalMinor =
              decimalTextToMinor(
                record
                  .totalPrice
              );

            return {
              partId:
                record.partId as
                  string |
                  null,

              description:
                record
                  .description,

              quantity:
                record
                  .quantity,

              unitPriceMinor:
                Number(
                  unitMinor
                ),

              totalPriceMinor:
                Number(
                  totalMinor
                ),
            };
          }
        );

  return {
    diagnosis:
      revision
        .diagnosisSnapshot,

    totalAmountMinor:
      Number(
        prismaMoneyToMinor(
          revision
            .totalAmount
        )
      ),

    items,
  };
}

export class CommercialQuoteRevisionService {
  async publishCommercialRevision(
    organizationId:
      string,
    actorUserId:
      string,
    operationId:
      string,
    serviceOrderId:
      string,
    input:
      PublishCommercialQuoteRevisionInput
  ): Promise<FinanceCommandResult> {
    const endpoint =
      `/api/v1/service-orders/${serviceOrderId}/quotes/revise`;

    const command =
      'FIN_F02_QUOTE_REVISE';

    const requestHash =
      computeCanonicalHash({
        serviceOrderId,

        diagnosis:
          input.diagnosis,

        items:
          input.items.map(
            (
              item
            ) => ({
              id:
                item.id ??
                null,

              partId:
                item.partId ??
                null,

              description:
                item.description,

              quantity:
                item.quantity,

              unitPriceMinor:
                item
                  .unitPriceMinor,
            })
          ),

        changeReason:
          input.changeReason,
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
           * Frozen common lock root.
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
                  'COMMERCIAL_REVISION_REQUIRES_EXECUTION_STATUS',

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
                  'COMMERCIAL_REVISION_REQUIRES_APPROVED_QUOTE',
              } as
                Prisma.InputJsonValue
            );
          }

          /**
           * Lock all QuoteRevision rows in lexical UUID order.
           * This satisfies the frozen multi-row lock ordering and
           * also serializes revision-number inspection.
           */
          await tx
            .$queryRaw(
              Prisma.sql`
                SELECT id
                FROM service_order_quote_revisions
                WHERE serviceOrderId =
                  ${order.id}
                ORDER BY id
                FOR UPDATE
              `
            );

          const lastApproved =
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
            !lastApproved ||
            lastApproved
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

          /**
           * Before creating a new commercial revision, the live
           * execution scope must still semantically match the last
           * approved revision. This detects any bypass/drift.
           */
          const currentSemanticScope:
            CommercialSemanticScope = {
              diagnosis:
                order
                  .diagnosis,

              totalAmountMinor:
                Number(
                  prismaMoneyToMinor(
                    order
                      .totalAmount
                  )
                ),

              items:
                order
                  .items
                  .map(
                    semanticLineFromStored
                  ),
            };

          const approvedSemanticScope =
            semanticScopeFromApprovedRevision(
              lastApproved
            );

          if (
            commercialScopeFingerprint(
              currentSemanticScope
            ) !==
            commercialScopeFingerprint(
              approvedSemanticScope
            )
          ) {
            return complete(
              409,
              {
                error:
                  'EXECUTION_SCOPE_DIVERGED_FROM_APPROVED_QUOTE',
              } as
                Prisma.InputJsonValue
            );
          }

          const duplicateIds =
            input.items
              .filter(
                (
                  item
                ) =>
                  Boolean(
                    item.id
                  )
              )
              .map(
                (
                  item
                ) =>
                  item.id!
              );

          if (
            new Set(
              duplicateIds
            ).size !==
            duplicateIds.length
          ) {
            return complete(
              409,
              {
                error:
                  'DUPLICATE_SERVICE_ORDER_ITEM_ID',
              } as
                Prisma.InputJsonValue
            );
          }

          const currentItemIds =
            new Set(
              order
                .items
                .map(
                  (
                    item
                  ) =>
                    item.id
                )
            );

          for (
            const itemId of
            duplicateIds
          ) {
            if (
              !currentItemIds
                .has(
                  itemId
                )
            ) {
              return complete(
                409,
                {
                  error:
                    'SERVICE_ORDER_ITEM_NOT_IN_ORDER',

                  serviceOrderItemId:
                    itemId,
                } as
                  Prisma.InputJsonValue
              );
            }
          }

          const requestedPartIds =
            Array.from(
              new Set(
                input.items
                  .map(
                    (
                      item
                    ) =>
                      item.partId ??
                      null
                  )
                  .filter(
                    (
                      value
                    ): value is string =>
                      typeof value ===
                      'string'
                  )
              )
            );

          const parts =
            requestedPartIds.length >
              0
              ? await tx
                  .part
                  .findMany({
                    where: {
                      id: {
                        in:
                          requestedPartIds,
                      },
                    },
                  })
              : [];

          if (
            parts.length !==
            requestedPartIds.length
          ) {
            return complete(
              409,
              {
                error:
                  'QUOTE_PART_NOT_FOUND',
              } as
                Prisma.InputJsonValue
            );
          }

          const partById =
            new Map(
              parts.map(
                (
                  part
                ) => [
                  part.id,
                  part,
                ]
              )
            );

          const plannedItems:
            PlannedItem[] =
              [];

          try {
            for (
              const item of
              input.items
            ) {
              plannedItems.push({
                id:
                  item.id ??
                  randomUUID(),

                existing:
                  Boolean(
                    item.id
                  ),

                partId:
                  item.partId ??
                  null,

                description:
                  item.description,

                quantity:
                  item.quantity,

                unitPriceMinor:
                  item
                    .unitPriceMinor,

                totalPriceMinor:
                  calculateCommercialLineTotalMinor(
                    item.quantity,
                    item
                      .unitPriceMinor
                  ),
              });
            }
          } catch {
            return complete(
              409,
              {
                error:
                  'COMMERCIAL_MONEY_RANGE_INVALID',
              } as
                Prisma.InputJsonValue
            );
          }

          let totalMinor:
            bigint;

          try {
            totalMinor =
              calculateCommercialTotalMinor(
                input
                  .items
              );
          } catch {
            return complete(
              409,
              {
                error:
                  'COMMERCIAL_TOTAL_RANGE_INVALID',
              } as
                Prisma.InputJsonValue
            );
          }

          if (
            totalMinor <=
            0n
          ) {
            return complete(
              409,
              {
                error:
                  'COMMERCIAL_TOTAL_MUST_BE_POSITIVE',
              } as
                Prisma.InputJsonValue
            );
          }

          const proposedSemanticScope:
            CommercialSemanticScope = {
              diagnosis:
                input
                  .diagnosis,

              totalAmountMinor:
                Number(
                  totalMinor
                ),

              items:
                plannedItems
                  .map(
                    semanticLineFromPlanned
                  ),
            };

          const currentFingerprint =
            commercialScopeFingerprint(
              currentSemanticScope
            );

          const proposedFingerprint =
            commercialScopeFingerprint(
              proposedSemanticScope
            );

          if (
            proposedFingerprint ===
            currentFingerprint
          ) {
            return complete(
              409,
              {
                error:
                  'COMMERCIAL_REVISION_HAS_NO_CHANGES',
              } as
                Prisma.InputJsonValue
            );
          }

          const changedFields:
            string[] =
              [];

          if (
            input.diagnosis !==
            order.diagnosis
          ) {
            changedFields.push(
              'diagnosis'
            );
          }

          if (
            Number(
              totalMinor
            ) !==
            currentSemanticScope
              .totalAmountMinor
          ) {
            changedFields.push(
              'totalAmount'
            );
          }

          const currentItemsFingerprint =
            commercialScopeFingerprint({
              diagnosis:
                null,

              totalAmountMinor:
                0,

              items:
                currentSemanticScope
                  .items,
            });

          const proposedItemsFingerprint =
            commercialScopeFingerprint({
              diagnosis:
                null,

              totalAmountMinor:
                0,

              items:
                proposedSemanticScope
                  .items,
            });

          if (
            currentItemsFingerprint !==
            proposedItemsFingerprint
          ) {
            changedFields.push(
              'serviceItems'
            );
          }

          const latestRevision =
            await tx
              .serviceOrderQuoteRevision
              .findFirst({
                where: {
                  serviceOrderId:
                    order.id,
                },

                orderBy: {
                  revisionNumber:
                    'desc',
                },

                select: {
                  revisionNumber:
                    true,
                },
              });

          if (
            !latestRevision
          ) {
            return complete(
              409,
              {
                error:
                  'QUOTE_REVISION_HISTORY_MISSING',
              } as
                Prisma.InputJsonValue
            );
          }

          const nextRevisionNumber =
            latestRevision
              .revisionNumber +
            1;

          const serviceItemsSnapshot =
            plannedItems
              .map(
                (
                  item
                ) => ({
                  id:
                    item.id,

                  partId:
                    item.partId,

                  description:
                    item.description,

                  quantity:
                    item.quantity,

                  unitPrice:
                    moneyMinorToDecimalText(
                      BigInt(
                        item
                          .unitPriceMinor
                      )
                    ),

                  totalPrice:
                    moneyMinorToDecimalText(
                      item
                        .totalPriceMinor
                    ),
                })
              );

          const partsSnapshot =
            requestedPartIds
              .map(
                (
                  partId
                ) => {
                  const part =
                    partById
                      .get(
                        partId
                      );

                  if (!part) {
                    throw new Error(
                      'Resolved part disappeared inside transaction'
                    );
                  }

                  return {
                    id:
                      part.id,

                    name:
                      part.name,

                    sku:
                      part.sku,

                    price:
                      part.price
                        .toFixed(
                          2
                        ),
                  };
                }
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
            moneyMinorToDecimalText(
              totalMinor
            );

          const quoteSnapshot = {
            snapshotVersion:
              1,

            serviceOrderId:
              order.id,

            organizationId:
              order
                .organizationId,

            customerId:
              order.customerId,

            diagnosis:
              input.diagnosis,

            totalAmount,

            serviceItems:
              serviceItemsSnapshot,

            parts:
              partsSnapshot,
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
                    order
                      .organizationId,

                  customerId:
                    order
                      .customerId,

                  revisionNumber:
                    nextRevisionNumber,

                  diagnosisSnapshot:
                    input.diagnosis,

                  serviceItemsSnapshot:
                    serviceItemsSnapshot as
                      Prisma.InputJsonValue,

                  partsSnapshot:
                    partsSnapshot as
                      Prisma.InputJsonValue,

                  totalAmount:
                    new Prisma.Decimal(
                      totalAmount
                    ),

                  changeType:
                    QuoteChangeType
                      .COMMERCIAL_CHANGE,

                  changeReason:
                    input.changeReason,

                  quoteSnapshot:
                    quoteSnapshot as
                      Prisma.InputJsonValue,

                  quoteHash,

                  createdByUserId:
                    actorUserId,
                },
              });

          const retainedExistingIds =
            plannedItems
              .filter(
                (
                  item
                ) =>
                  item.existing
              )
              .map(
                (
                  item
                ) =>
                  item.id
              );

          await tx
            .serviceOrderItem
            .deleteMany({
              where: {
                serviceOrderId:
                  order.id,

                ...(
                  retainedExistingIds
                    .length >
                    0
                    ? {
                        id: {
                          notIn:
                            retainedExistingIds,
                        },
                      }
                    : {}
                ),
              },
            });

          for (
            const item of
            plannedItems
          ) {
            const itemData = {
              partId:
                item.partId,

              description:
                item.description,

              quantity:
                item.quantity,

              unitPrice:
                new Prisma.Decimal(
                  moneyMinorToDecimalText(
                    BigInt(
                      item
                        .unitPriceMinor
                    )
                  )
                ),

              totalPrice:
                new Prisma.Decimal(
                  moneyMinorToDecimalText(
                    item
                      .totalPriceMinor
                  )
                ),
            };

            if (
              item.existing
            ) {
              await tx
                .serviceOrderItem
                .update({
                  where: {
                    id:
                      item.id,
                  },

                  data:
                    itemData,
                });
            } else {
              await tx
                .serviceOrderItem
                .create({
                  data: {
                    id:
                      item.id,

                    serviceOrderId:
                      order.id,

                    ...itemData,
                  },
                });
            }
          }

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
                    order
                      .lastApprovedQuoteRevisionId,
                },

                data: {
                  diagnosis:
                    input.diagnosis,

                  totalAmount:
                    new Prisma.Decimal(
                      totalAmount
                    ),

                  currentQuoteRevisionId:
                    quoteRevision.id,

                  status:
                    ServiceOrderStatus
                      .AGUARDANDO_REAPROVACAO,
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
                    .AGUARDANDO_REAPROVACAO,

                changedById:
                  actorUserId,

                notes:
                  input.changeReason,
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
                    .AGUARDANDO_REAPROVACAO,
              },

              tx
            );

          await tx
            .financialAuditEvent
            .create({
              data: {
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
                  'QUOTE_REVISION_PUBLISHED',

                entityType:
                  'SERVICE_ORDER_QUOTE_REVISION',

                entityId:
                  quoteRevision.id,

                operationId,

                ordinal:
                  1,

                metadata: {
                  revisionNumber:
                    nextRevisionNumber,

                  changeType:
                    QuoteChangeType
                      .COMMERCIAL_CHANGE,

                  previousLastApprovedQuoteRevisionId:
                    order
                      .lastApprovedQuoteRevisionId,

                  changedFields,

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

          const responseBody = {
            order: {
              id:
                updatedOrder.id,

              status:
                updatedOrder
                  .status,

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

              changedFields,

              createdAt:
                quoteRevision
                  .createdAt
                  .toISOString(),
            },
          } as
            Prisma.InputJsonValue;

          return complete(
            201,
            responseBody
          );
        }
      );
  }
}

export const commercialQuoteRevisionService =
  new CommercialQuoteRevisionService();
