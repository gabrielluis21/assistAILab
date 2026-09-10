import {
  PaymentStatus,
  Prisma,
} from '@prisma/client';

import {
  prisma,
} from '../../core/database/prisma.js';

import {
  decimalToMinorUnits,
} from '../../core/money/money.js';

import {
  ConflictError,
  NotFoundError,
} from '../../core/utils/errors.js';

import {
  buildCustomerFinancialObligation,
  type CustomerConfirmedPaymentProjection,
  type CustomerFinancialProjection,
} from './customer_financial_projection.rules.js';

function civilDateKey(
  value:
    Date
): string {
  return value
    .toISOString()
    .slice(
      0,
      10
    );
}

export class CustomerFinancialProjectionService {
  async getForCustomer(
    customerId:
      string,
    serviceOrderId:
      string,
    now =
      new Date()
  ): Promise<
    CustomerFinancialProjection
  > {
    /**
     * Read-only Finance Core projection.
     *
     * One interactive transaction gives the projection one coherent
     * database snapshot while Payment confirmation/reschedule/cancel
     * may be committing concurrently.
     */
    return prisma
      .$transaction(
        async (
          tx
        ) => {
          /**
           * CUSTOMER ownership is global:
           * ServiceOrder id + authenticated customerId.
           * organizationId is derived from the owned ServiceOrder.
           */
          const order =
            await tx
              .serviceOrder
              .findFirst({
                where: {
                  id:
                    serviceOrderId,

                  customerId,
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

                  organization: {
                    select: {
                      timezone:
                        true,
                    },
                  },
                },
              });

          if (
            !order
          ) {
            throw new NotFoundError(
              'Service Order not found'
            );
          }

          /**
           * Legacy/pre-Receivable orders never receive a synthetic debt.
           */
          if (
            order
              .financeCoreVersion !==
            2
          ) {
            return {
              serviceOrderId:
                order.id,

              obligation:
                null,

              confirmedPayments:
                [],
            };
          }

          /**
           * Current FIN-F02 lifecycle has one Receivable per ServiceOrder.
           * The DB protects one ACTIVE row; the command flow does not
           * implement multi-obligation customer projection yet.
           * Fail closed if unexpected historical multiplicity appears.
           */
          const receivables =
            await tx
              .receivable
              .findMany({
                where: {
                  serviceOrderId:
                    order.id,

                  customerId,

                  organizationId:
                    order
                      .organizationId,
                },

                orderBy: [
                  {
                    issuedAt:
                      'desc',
                  },
                  {
                    id:
                      'asc',
                  },
                ],

                take:
                  2,
              });

          if (
            receivables.length ===
            0
          ) {
            return {
              serviceOrderId:
                order.id,

              obligation:
                null,

              confirmedPayments:
                [],
            };
          }

          if (
            receivables.length !==
            1
          ) {
            throw new ConflictError(
              'CUSTOMER_FINANCIAL_PROJECTION_AMBIGUOUS_RECEIVABLE'
            );
          }

          const receivable =
            receivables[0];

          const schedule =
            await tx
              .receivableSchedule
              .findUnique({
                where: {
                  receivableId_version: {
                    receivableId:
                      receivable.id,

                    version:
                      receivable
                        .currentScheduleVersion,
                  },
                },

                select: {
                  id:
                    true,

                  version:
                    true,
                },
              });

          if (
            !schedule
          ) {
            throw new ConflictError(
              'CUSTOMER_FINANCIAL_PROJECTION_CURRENT_SCHEDULE_INVALID'
            );
          }

          const [
            installments,
            allocations,
            payments,
          ] =
            await Promise.all([
              tx
                .receivableInstallment
                .findMany({
                  where: {
                    receivableId:
                      receivable.id,
                  },

                  select: {
                    id:
                      true,

                    scheduleId:
                      true,

                    scheduleVersion:
                      true,

                    sequence:
                      true,

                    amount:
                      true,

                    dueDate:
                      true,
                  },

                  orderBy: [
                    {
                      scheduleVersion:
                        'asc',
                    },
                    {
                      sequence:
                        'asc',
                    },
                    {
                      id:
                        'asc',
                    },
                  ],
                }),

              tx
                .paymentAllocation
                .findMany({
                  where: {
                    receivableId:
                      receivable.id,
                  },

                  select: {
                    id:
                      true,

                    organizationId:
                      true,

                    customerId:
                      true,

                    serviceOrderId:
                      true,

                    installmentId:
                      true,

                    paymentId:
                      true,

                    amount:
                      true,
                  },

                  orderBy: {
                    id:
                      'asc',
                  },
                }),

              tx
                .payment
                .findMany({
                  where: {
                    organizationId:
                      order
                        .organizationId,

                    customerId,

                    serviceOrderId:
                      order.id,
                  },

                  select: {
                    id:
                      true,

                    amount:
                      true,

                    method:
                      true,

                    status:
                      true,

                    paidAt:
                      true,

                    cardInstallmentCount:
                      true,
                  },
                }),
            ]);

          const currentInstallments =
            installments
              .filter(
                (
                  installment
                ) =>
                  installment
                    .scheduleId ===
                    schedule.id &&
                  installment
                    .scheduleVersion ===
                    schedule.version
              );

          /**
           * FIN-F02 v1 schedules intentionally contain exactly one
           * outstanding installment. Do not guess if DB state diverges.
           */
          if (
            currentInstallments
              .length !==
            1
          ) {
            throw new ConflictError(
              'CUSTOMER_FINANCIAL_PROJECTION_CURRENT_INSTALLMENT_INVALID'
            );
          }

          const installmentIds =
            new Set(
              installments.map(
                (
                  installment
                ) =>
                  installment.id
              )
            );

          const paymentsById =
            new Map(
              payments.map(
                (
                  payment
                ) => [
                  payment.id,
                  payment,
                ]
              )
            );

          const allocatedByPayment =
            new Map<
              string,
              number
            >();

          let allocatedAmountMinor =
            0;

          for (
            const allocation of
            allocations
          ) {
            if (
              allocation
                .organizationId !==
                order
                  .organizationId ||
              allocation
                .customerId !==
                customerId ||
              allocation
                .serviceOrderId !==
                order.id ||
              !installmentIds.has(
                allocation
                  .installmentId
              )
            ) {
              throw new ConflictError(
                'CUSTOMER_FINANCIAL_PROJECTION_ALLOCATION_AUTHORITY_MISMATCH'
              );
            }

            const payment =
              paymentsById
                .get(
                  allocation
                    .paymentId
                );

            if (
              !payment ||
              payment.status !==
                PaymentStatus
                  .CONFIRMED
            ) {
              throw new ConflictError(
                'CUSTOMER_FINANCIAL_PROJECTION_ALLOCATION_PAYMENT_INVALID'
              );
            }

            const allocationMinor =
              decimalToMinorUnits(
                allocation.amount
              );

            allocatedAmountMinor +=
              allocationMinor;

            allocatedByPayment
              .set(
                payment.id,
                (
                  allocatedByPayment
                    .get(
                      payment.id
                    ) ??
                  0
                ) +
                  allocationMinor
              );
          }

          const confirmedPayments:
            CustomerConfirmedPaymentProjection[] =
              [];

          for (
            const payment of
            payments
          ) {
            if (
              payment.status !==
              PaymentStatus
                .CONFIRMED
            ) {
              continue;
            }

            const paymentAmountMinor =
              decimalToMinorUnits(
                payment.amount
              );

            const effectiveAllocation =
              allocatedByPayment
                .get(
                  payment.id
                ) ??
              0;

            /**
             * FIN-F02 confirmation is atomic with full PaymentAllocation.
             * A CONFIRMED row without exact allocation is contradictory
             * financial state and must not be silently shown to CUSTOMER.
             */
            if (
              effectiveAllocation !==
              paymentAmountMinor ||
              !payment.paidAt
            ) {
              throw new ConflictError(
                'CUSTOMER_FINANCIAL_PROJECTION_CONFIRMED_PAYMENT_INVALID'
              );
            }

            confirmedPayments
              .push({
                amountMinor:
                  paymentAmountMinor,

                method:
                  payment.method,

                paidAt:
                  payment
                    .paidAt
                    .toISOString(),

                cardInstallmentCount:
                  payment
                    .cardInstallmentCount,
              });
          }

          confirmedPayments
            .sort(
              (
                left,
                right
              ) =>
                left.paidAt
                  .localeCompare(
                    right.paidAt
                  ) ||
                left.method
                  .localeCompare(
                    right.method
                  ) ||
                left.amountMinor -
                  right.amountMinor
            );

          const totalAmountMinor =
            decimalToMinorUnits(
              receivable
                .totalAmount
            );

          let obligation;

          try {
            obligation =
              buildCustomerFinancialObligation({
                lifecycleStatus:
                  receivable
                    .lifecycleStatus,

                totalAmountMinor,

                allocatedAmountMinor,

                currentDueDateKey:
                  civilDateKey(
                    currentInstallments[0]
                      .dueDate
                  ),

                organizationTimeZone:
                  order
                    .organization
                    .timezone,

                now,
              });
          } catch (
            error
          ) {
            if (
              error instanceof
              RangeError
            ) {
              throw new ConflictError(
                'CUSTOMER_FINANCIAL_PROJECTION_INTEGRITY_CONFLICT'
              );
            }

            throw error;
          }

          return {
            serviceOrderId:
              order.id,

            obligation,

            confirmedPayments,
          };
        },
        {
          isolationLevel:
            Prisma
              .TransactionIsolationLevel
              .RepeatableRead,
        }
      );
  }
}

export const customerFinancialProjectionService =
  new CustomerFinancialProjectionService();
