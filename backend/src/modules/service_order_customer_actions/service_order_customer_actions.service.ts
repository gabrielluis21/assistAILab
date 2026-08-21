import {
  CustomerEventType,
  EquipmentOwnerType,
  ServiceOrderStatus,
} from '@prisma/client';

import {
  prisma,
} from '../../core/database/prisma.js';

import {
  ConflictError,
  NotFoundError,
} from '../../core/utils/errors.js';

import {
  customerEventService,
} from '../customer_relationship/customer_event.service.js';

import {
  serviceOrderCustomerRelationshipService,
} from '../customer_relationship/service_order_customer_relationship.service.js';

import {
  isValidStatusTransition,
} from '../service_orders/service_order_state_machine.js';

import type {
  CustomerCancelReturnInput,
  MarkReturnedInput,
  QuoteDecisionInput,
} from './service_order_customer_actions.schema.js';

const RETURN_REQUEST_TITLE =
  'Devolução solicitada';

function requireValidCancellation(
  status:
    ServiceOrderStatus
) {
  if (
    !isValidStatusTransition(
      status,
      ServiceOrderStatus.CANCELADO
    )
  ) {
    throw new ConflictError(
      `Service Order cannot be cancelled from status ${status}`
    );
  }
}

export class ServiceOrderCustomerActionsService {
  /**
   * ========================================================
   * C5 — CUSTOMER CANCEL + RETURN REQUEST
   * ========================================================
   *
   * O Customer cancela a própria OS e registra
   * explicitamente que deseja a devolução física
   * do Equipment.
   *
   * A solicitação de devolução é persistida como
   * CustomerEvent OTHER com kind estável em metadata,
   * evitando migration apenas para este estado auxiliar.
   */
  async cancelAndRequestReturn(
    orderId:
      string,
    customerId:
      string,
    changedById:
      string,
    input:
      CustomerCancelReturnInput
  ) {
    return prisma
      .$transaction(
        async (
          tx
        ) => {
          const order =
            await tx
              .serviceOrder
              .findFirst({
                where: {
                  id:
                    orderId,

                  customerId,
                },

                include: {
                  equipment: {
                    select: {
                      id:
                        true,

                      ownerType:
                        true,

                      customerId:
                        true,

                      organizationId:
                        true,
                    },
                  },
                },
              });

          if (!order) {
            throw new NotFoundError(
              'Service Order not found'
            );
          }

          /**
           * Equipment adquirido pela assistência
           * não pode ser solicitado como devolução
           * ao Customer por este fluxo.
           */
          if (
            order.equipment.ownerType !==
              EquipmentOwnerType.CUSTOMER ||
            order.equipment.customerId !==
              customerId
          ) {
            throw new ConflictError(
              'Service Order Equipment is no longer customer-owned'
            );
          }

          const existingReturnRequest =
            await tx
              .customerEvent
              .findFirst({
                where: {
                  serviceOrderId:
                    order.id,

                  customerId,

                  organizationId:
                    order.organizationId,

                  type:
                    CustomerEventType.OTHER,

                  title:
                    RETURN_REQUEST_TITLE,
                },
              });

          let currentOrder =
            order;

          let statusChanged =
            false;

          /**
           * Se já estiver CANCELADO por outro fluxo
           * (por exemplo, orçamento rejeitado),
           * ainda permitimos registrar o pedido de
           * devolução sem duplicar cancelamento.
           */
          if (
            order.status !==
            ServiceOrderStatus.CANCELADO
          ) {
            requireValidCancellation(
              order.status
            );

            const updateResult =
              await tx
                .serviceOrder
                .updateMany({
                  where: {
                    id:
                      order.id,

                    customerId,

                    status:
                      order.status,
                  },

                  data: {
                    status:
                      ServiceOrderStatus
                        .CANCELADO,
                  },
                });

            if (
              updateResult.count !==
              1
            ) {
              throw new ConflictError(
                'Service Order status changed concurrently. Reload the order and try again.'
              );
            }

            await tx
              .serviceOrderStatusHistory
              .create({
                data: {
                  serviceOrderId:
                    order.id,

                  previousStatus:
                    order.status,

                  newStatus:
                    ServiceOrderStatus
                      .CANCELADO,

                  changedById,

                  notes:
                    input.reason ??
                    'Cancelamento solicitado pelo cliente com devolução do equipamento',
                },
              });

            /**
             * Cancelamento real gera o lifecycle
             * SERVICE_ORDER_CANCELLED.
             */
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
                    order.status,

                  newStatus:
                    ServiceOrderStatus
                      .CANCELADO,
                },

                tx
              );

            currentOrder =
              await tx
                .serviceOrder
                .findUniqueOrThrow({
                  where: {
                    id:
                      order.id,
                  },

                  include: {
                    equipment: {
                      select: {
                        id:
                          true,

                        ownerType:
                          true,

                        customerId:
                          true,

                        organizationId:
                          true,
                      },
                    },
                  },
                });

            statusChanged =
              true;
          }

          let returnRequestEvent =
            existingReturnRequest;

          if (
            !returnRequestEvent
          ) {
            returnRequestEvent =
              await customerEventService
                .createServiceOrderEvent(
                  {
                    customerId:
                      order.customerId,

                    organizationId:
                      order.organizationId,

                    serviceOrderId:
                      order.id,

                    type:
                      CustomerEventType
                        .OTHER,

                    title:
                      RETURN_REQUEST_TITLE,

                    description:
                      input.reason ??
                      'O cliente solicitou a devolução do equipamento.',

                    metadata: {
                      kind:
                        'SERVICE_ORDER_RETURN_REQUESTED',

                      requestedById:
                        changedById,

                      ...(input.reason
                        ? {
                            reason:
                              input.reason,
                          }
                        : {}),
                    },
                  },

                  tx
                );
          }

          return {
            order:
              currentOrder,

            returnRequested:
              true,

            statusChanged,

            alreadyProcessed:
              !statusChanged &&
              Boolean(
                existingReturnRequest
              ),

            returnRequest: {
              id:
                returnRequestEvent.id,

              createdAt:
                returnRequestEvent.createdAt,
            },
          };
        }
      );
  }

  /**
   * ========================================================
   * C5 — STAFF CONFIRMS PHYSICAL RETURN
   * ========================================================
   *
   * A OS continua CANCELADO.
   * Não introduzimos um novo status operacional.
   *
   * O evento SERVICE_ORDER_RETURNED representa
   * a entrega física do Equipment ao Customer.
   */
  async markEquipmentReturned(
    orderId:
      string,
    organizationId:
      string,
    changedById:
      string,
    input:
      MarkReturnedInput
  ) {
    return prisma
      .$transaction(
        async (
          tx
        ) => {
          const order =
            await tx
              .serviceOrder
              .findFirst({
                where: {
                  id:
                    orderId,

                  organizationId,
                },

                include: {
                  equipment: {
                    select: {
                      id:
                        true,

                      ownerType:
                        true,

                      customerId:
                        true,

                      organizationId:
                        true,
                    },
                  },
                },
              });

          if (!order) {
            throw new NotFoundError(
              'Service Order not found'
            );
          }

          if (
            order.status !==
            ServiceOrderStatus.CANCELADO
          ) {
            throw new ConflictError(
              'Equipment return can only be confirmed for a cancelled Service Order'
            );
          }

          if (
            order.equipment.ownerType !==
              EquipmentOwnerType.CUSTOMER ||
            order.equipment.customerId !==
              order.customerId
          ) {
            throw new ConflictError(
              'Service Order Equipment is no longer customer-owned'
            );
          }

          /**
           * Só confirmamos devolução quando houve
           * pedido explícito de devolução.
           */
          const returnRequest =
            await tx
              .customerEvent
              .findFirst({
                where: {
                  serviceOrderId:
                    order.id,

                  customerId:
                    order.customerId,

                  organizationId,

                  type:
                    CustomerEventType.OTHER,

                  title:
                    RETURN_REQUEST_TITLE,
                },
              });

          if (!returnRequest) {
            throw new ConflictError(
              'No equipment return request exists for this Service Order'
            );
          }

          /**
           * Retry idempotente.
           */
          const existingReturnedEvent =
            await tx
              .customerEvent
              .findFirst({
                where: {
                  serviceOrderId:
                    order.id,

                  customerId:
                    order.customerId,

                  organizationId,

                  type:
                    CustomerEventType
                      .SERVICE_ORDER_RETURNED,
                },
              });

          if (
            existingReturnedEvent
          ) {
            return {
              order,

              returned:
                true,

              alreadyProcessed:
                true,

              returnedEvent: {
                id:
                  existingReturnedEvent.id,

                createdAt:
                  existingReturnedEvent.createdAt,
              },
            };
          }

          const returnedEvent =
            await customerEventService
              .createServiceOrderEvent(
                {
                  customerId:
                    order.customerId,

                  organizationId,

                  serviceOrderId:
                    order.id,

                  type:
                    CustomerEventType
                      .SERVICE_ORDER_RETURNED,

                  title:
                    'Equipamento devolvido',

                  description:
                    input.notes ??
                    'O equipamento foi devolvido fisicamente ao cliente.',

                  metadata: {
                    changedById,

                    returnRequestEventId:
                      returnRequest.id,

                    equipmentId:
                      order.equipmentId,

                    ...(input.notes
                      ? {
                          notes:
                            input.notes,
                        }
                      : {}),
                  },
                },

                tx
              );

          return {
            order,

            returned:
              true,

            alreadyProcessed:
              false,

            returnedEvent: {
              id:
                returnedEvent.id,

              createdAt:
                returnedEvent.createdAt,
            },
          };
        }
      );
  }

  /**
   * ========================================================
   * C6/C7 — CUSTOMER QUOTE DECISION
   * ========================================================
   *
   * APPROVE:
   * AGUARDANDO_APROVACAO -> EM_EXECUCAO
   *
   * REJECT:
   * AGUARDANDO_APROVACAO -> CANCELADO
   * + SERVICE_ORDER_NOT_APPROVED
   *
   * Rejeição não gera também
   * SERVICE_ORDER_CANCELLED.
   */
  async decideQuote(
    orderId:
      string,
    customerId:
      string,
    changedById:
      string,
    input:
      QuoteDecisionInput
  ) {
    return prisma
      .$transaction(
        async (
          tx
        ) => {
          const order =
            await tx
              .serviceOrder
              .findFirst({
                where: {
                  id:
                    orderId,

                  customerId,
                },
              });

          if (!order) {
            throw new NotFoundError(
              'Service Order not found'
            );
          }

          /**
           * ==================================================
           * APPROVE
           * ==================================================
           */
          if (
            input.decision ===
            'APPROVE'
          ) {
            /**
             * Retry idempotente enquanto a OS
             * ainda está exatamente EM_EXECUCAO.
             */
            if (
              order.status ===
              ServiceOrderStatus
                .EM_EXECUCAO
            ) {
              return {
                order,

                decision:
                  'APPROVE' as const,

                alreadyProcessed:
                  true,
              };
            }

            if (
              order.status !==
              ServiceOrderStatus
                .AGUARDANDO_APROVACAO
            ) {
              throw new ConflictError(
                'Service Order is not awaiting approval'
              );
            }

            const updateResult =
              await tx
                .serviceOrder
                .updateMany({
                  where: {
                    id:
                      order.id,

                    customerId,

                    status:
                      ServiceOrderStatus
                        .AGUARDANDO_APROVACAO,
                  },

                  data: {
                    status:
                      ServiceOrderStatus
                        .EM_EXECUCAO,
                  },
                });

            if (
              updateResult.count !==
              1
            ) {
              throw new ConflictError(
                'Service Order status changed concurrently. Reload the order and try again.'
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
                      .AGUARDANDO_APROVACAO,

                  newStatus:
                    ServiceOrderStatus
                      .EM_EXECUCAO,

                  changedById,

                  notes:
                    input.reason ??
                    'Orçamento aprovado pelo cliente',
                },
              });

            /**
             * Transição operacional:
             * atualmente não gera lifecycle CRM.
             */
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
                      .AGUARDANDO_APROVACAO,

                  newStatus:
                    ServiceOrderStatus
                      .EM_EXECUCAO,
                },

                tx
              );

            const updated =
              await tx
                .serviceOrder
                .findUniqueOrThrow({
                  where: {
                    id:
                      order.id,
                  },
                });

            return {
              order:
                updated,

              decision:
                'APPROVE' as const,

              alreadyProcessed:
                false,
            };
          }

          /**
           * ==================================================
           * REJECT
           * ==================================================
           */

          const existingNotApproved =
            await tx
              .customerEvent
              .findFirst({
                where: {
                  serviceOrderId:
                    order.id,

                  customerId:

                    order.customerId,

                  organizationId:
                    order.organizationId,

                  type:
                    CustomerEventType
                      .SERVICE_ORDER_NOT_APPROVED,
                },
              });

          if (
            existingNotApproved
          ) {
            return {
              order,

              decision:
                'REJECT' as const,

              alreadyProcessed:
                true,
            };
          }

          if (
            order.status !==
            ServiceOrderStatus
              .AGUARDANDO_APROVACAO
          ) {
            throw new ConflictError(
              'Service Order is not awaiting approval'
            );
          }

          const updateResult =
            await tx
              .serviceOrder
              .updateMany({
                where: {
                  id:
                    order.id,

                  customerId,

                  status:
                    ServiceOrderStatus
                      .AGUARDANDO_APROVACAO,
                },

                data: {
                  status:
                    ServiceOrderStatus
                      .CANCELADO,
                },
              });

          if (
            updateResult.count !==
            1
          ) {
            throw new ConflictError(
              'Service Order status changed concurrently. Reload the order and try again.'
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
                    .AGUARDANDO_APROVACAO,

                newStatus:
                  ServiceOrderStatus
                    .CANCELADO,

                changedById,

                notes:
                  input.reason ??
                  'Orçamento não aprovado pelo cliente',
              },
            });

          /**
           * Fluxo específico de não aprovação.
           *
           * NÃO chama registerStatusTransition()
           * para evitar SERVICE_ORDER_CANCELLED.
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
                  ServiceOrderStatus
                    .AGUARDANDO_APROVACAO,

                changedById,

                reason:
                  input.reason,
              },

              tx
            );

          const updated =
            await tx
              .serviceOrder
              .findUniqueOrThrow({
                where: {
                  id:
                    order.id,
                },
              });

          return {
            order:
              updated,

            decision:
              'REJECT' as const,

            alreadyProcessed:
              false,
          };
        }
      );
  }
}

export const serviceOrderCustomerActionsService =
  new ServiceOrderCustomerActionsService();
