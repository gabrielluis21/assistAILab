import {
    describe,
    it,
} from 'node:test';

import assert from 'node:assert/strict';

import {
    CustomerEventType,
    ServiceOrderStatus,
} from '@prisma/client';

import {
    mapServiceOrderStatusToCustomerEvent,
} from './service_order_customer_relationship.service.js';

describe(
    'Customer Relationship - Service Order Integration',
    () => {
        it(
            'ENTREGUE maps to SERVICE_ORDER_COMPLETED',
            () => {
                const result =
                    mapServiceOrderStatusToCustomerEvent(
                        ServiceOrderStatus.ENTREGUE
                    );

                assert.equal(
                    result,
                    CustomerEventType.SERVICE_ORDER_COMPLETED
                );
            }
        );

        it(
            'CANCELADO maps to SERVICE_ORDER_CANCELLED',
            () => {
                const result =
                    mapServiceOrderStatusToCustomerEvent(
                        ServiceOrderStatus.CANCELADO
                    );

                assert.equal(
                    result,
                    CustomerEventType.SERVICE_ORDER_CANCELLED
                );
            }
        );

        it(
            'AGUARDANDO_APROVACAO does not mean NOT_APPROVED',
            () => {
                const result =
                    mapServiceOrderStatusToCustomerEvent(
                        ServiceOrderStatus.AGUARDANDO_APROVACAO
                    );

                assert.equal(result, null);
            }
        );

        it(
            'operational states do not generate CRM lifecycle events',
            () => {
                const statuses = [
                    ServiceOrderStatus.DRAFT,
                    ServiceOrderStatus.DIAGNOSTICO,
                    ServiceOrderStatus.EM_EXECUCAO,
                    ServiceOrderStatus.PRONTO,
                ];

                for (const status of statuses) {
                    assert.equal(
                        mapServiceOrderStatusToCustomerEvent(
                            status
                        ),
                        null
                    );
                }
            }
        );
    }
);